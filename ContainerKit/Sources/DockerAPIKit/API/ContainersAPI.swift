import Foundation
import ContainerKit

/// Container lifecycle endpoints: list, inspect, start/stop/restart/kill,
/// remove, prune, wait.
public enum ContainersAPI {
    static let listFilters: Set<String> = ["status", "label", "name", "id", "ancestor", "network", "volume", "exited", "publish", "health"]

    public static func register(on router: inout DockerRouter, backend: DockerBackend, exits: ExitRecorder? = nil,
                                attaches: AttachRegistry? = nil, supervisor: Supervisor? = nil,
                                pending: PendingCopies? = nil, hosts: HostsSync? = nil,
                                waits: ExitWaits? = nil, health: HealthMonitor? = nil, renames: Renames = Renames(),
                                dockerSocket: String? = nil) {
        let directory = ContainerDirectory(backend: backend, exits: exits, health: health, renames: renames)

        router.add("POST", "/containers/create") { request in
            await respond { try await create(request, directory, backend, renames, dockerSocket: dockerSocket) }
        }
        router.add("POST", "/containers/{id}/rename") { request in
            await respond { try await rename(request, directory, backend, renames, dockerSocket: dockerSocket) }
        }
        router.add("GET", "/containers/json") { request in
            await respond { try await list(request, directory) }
        }
        router.add("GET", "/containers/{id}/json") { request in
            await respond {
                let item = try await directory.resolve(request.parameters["id"]!)
                return .json(ContainerModels.inspect(item, restartCount: await supervisor?.restartCount(item.name) ?? 0))
            }
        }
        router.add("POST", "/containers/{id}/start") { request in
            await respond {
                let item = try await directory.resolve(request.parameters["id"]!)
                if item.state == .running { return .notModified }
                await supervisor?.startedByHand(item.name)
                do {
                    try await engine {
                        // `docker run -it` attached first: boot with its stdio.
                        var attached = false
                        // Someone waits for this run's exit: catch it before the
                        // process can end (between boot and process start).
                        let expected = await waits?.isExpected(item.name) ?? false
                        let beforeStart: @Sendable () async -> Void = {
                            if expected { await waits?.begin(item.name, backend: backend) }
                        }
                        if let attaches {
                            attached = try await ExecAPI.startAttached(item.name, backend: backend, attaches: attaches,
                                                                       beforeStart: beforeStart)
                        }
                        if !attached {
                            // Over XPC, as `container start` does it — boot,
                            // then the init process — without a CLI process
                            // for every start.
                            try checkMountSources(item.container)
                            do {
                                try await backend.bootstrapContainer(item.name, stdio: ProcessStdio())
                                await beforeStart()
                                try await backend.startProcess(item.name, process: item.name)
                            } catch {
                                // Like `container start`: don't leave it half started.
                                try? await backend.stopContainer(item.name, timeout: 0, signal: nil)
                                throw portConflict(error, item.container) ?? error
                            }
                        }
                        // Files sent before the first start go in right after it
                        // (the apiserver copies only into running containers).
                        try await pending?.apply(item.name, backend: backend)
                    }
                } catch {
                    // Docker removes a --rm container whose start failed; docker
                    // run waits for that removal before reporting the error.
                    if item.container.configuration.labels[DockerLabels.autoRemove] == "true" {
                        try? await backend.deleteContainer(item.name, force: true)
                    }
                    throw error
                }
                // Names of its network neighbours, and its own name for them.
                await hosts?.sync()
                // Watch the new run now: an exit right after start would
                // otherwise come before the next scan and lose its code.
                await directory.exits?.scan()
                return .noContent
            }
        }
        router.add("POST", "/containers/{id}/stop") { request in
            await respond {
                let item = try await directory.resolve(request.parameters["id"]!)
                // First, even if it isn't running: a stop during a restart
                // delay cancels the pending restart, as in Docker.
                await supervisor?.stoppedByHand(item.name)
                if item.state != .running { return .notModified }
                try await engine {
                    try await backend.stopContainer(item.name, timeout: try request.int("t").map(Int32.init),
                                                    signal: request.query["signal"])
                }
                return .noContent
            }
        }
        router.add("POST", "/containers/{id}/restart") { request in
            await respond {
                let item = try await directory.resolve(request.parameters["id"]!)
                // A restart by hand: the stop must not trigger a restart; the
                // start afterwards clears it (and the restart count).
                await supervisor?.stoppedByHand(item.name)
                try await engine {
                    if item.state == .running {
                        try await backend.stopContainer(item.name, timeout: try request.int("t").map(Int32.init),
                                                        signal: request.query["signal"])
                    }
                    try await backend.startContainer(item.name)
                }
                await supervisor?.startedByHand(item.name)
                await directory.exits?.scan()
                return .noContent
            }
        }
        router.add("POST", "/containers/{id}/kill") { request in
            await respond {
                let item = try await directory.resolve(request.parameters["id"]!)
                guard item.state == .running else {
                    throw DockerAPIError(409, "cannot kill container: \(item.name): container \(item.id) is not running")
                }
                try await engine { try await backend.killContainer(item.name, signal: request.query["signal"] ?? "SIGKILL") }
                return .noContent
            }
        }
        router.add("DELETE", "/containers/{id}") { request in
            await respond {
                let item = try await directory.resolve(request.parameters["id"]!)
                let force = request.bool("force")
                if item.state == .running && !force {
                    throw DockerAPIError(409, "cannot remove container \"/\(item.name)\": container is running: stop the container before removing or force remove")
                }
                try await engine { try await backend.deleteContainer(item.name, force: force) }
                await pending?.forget(item.name)
                await supervisor?.forget(item.name)
                await renames.forget(item.name)
                // `-v`: the anonymous volumes this container created.
                if request.bool("v"), let volumes = item.container.configuration.labels[DockerLabels.anonymousVolumes] {
                    for volume in volumes.split(separator: ",") {
                        try? await backend.deleteVolume(String(volume))
                    }
                }
                return .noContent
            }
        }
        router.add("POST", "/containers/prune") { request in
            await respond { try await prune(request, directory, backend) }
        }
        router.add("POST", "/containers/{id}/wait") { request in
            await respond { try await wait(request, directory, backend, waits) }
        }
    }

    /// The runtime reports a taken host port as a nested `bind(…): Address
    /// already in use`; say which port, in Docker's words (tools match them).
    static func portConflict(_ error: Error, _ container: Container) -> DockerAPIError? {
        guard String(describing: error).contains("Address already in use") else { return nil }
        let taken = (container.configuration.publishedPorts ?? []).first { port in
            (port.proto ?? "tcp").lowercased() == "tcp" && !canBind(port.hostPort, port.hostAddress)
        }
        guard let taken else {
            return DockerAPIError(500, "driver failed programming external connectivity on endpoint \(container.id): a published port is already allocated by another program on this Mac")
        }
        let address = taken.hostAddress ?? "0.0.0.0"
        return DockerAPIError(500, "driver failed programming external connectivity on endpoint \(container.id): Bind for \(address):\(taken.hostPort) failed: port is already allocated (another program on this Mac listens on it)")
    }

    /// Whether `address:port` binds the way the runtime binds it (SO_REUSEADDR).
    static func canBind(_ port: Int, _ address: String?) -> Bool {
        let host = address ?? "0.0.0.0"
        let family = host.contains(":") ? AF_INET6 : AF_INET
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0, (0...65535).contains(port) else { return true }
        defer { close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        if family == AF_INET6 {
            var target = sockaddr_in6()
            target.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            target.sin6_family = sa_family_t(AF_INET6)
            target.sin6_port = UInt16(port).bigEndian
            guard inet_pton(AF_INET6, host, &target.sin6_addr) == 1 else { return true }
            return withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 }
            }
        }
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &target.sin_addr) == 1 else { return true }
        return withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    /// `container start` refuses to boot with a bind source that is gone;
    /// say which, rather than the runtime's error from deep in the boot.
    static func checkMountSources(_ container: Container) throws {
        for mount in container.configuration.mounts ?? [] where mount.volumeName == nil {
            guard let source = mount.source, source.hasPrefix("/") else { continue }
            if !FileManager.default.fileExists(atPath: source) {
                throw DockerAPIError(500, "mount source path '\(source)' does not exist")
            }
        }
    }

    // MARK: - Create

    struct CreateResponse: Encodable {
        let Id: String
        let Warnings: [String]
    }

    static func create(_ request: DockerRequest, _ directory: ContainerDirectory, _ backend: DockerBackend,
                       _ renames: Renames = Renames(), dockerSocket: String? = nil) async throws -> HTTPResponse {
        let body = request.http.body.isEmpty ? Data("{}".utf8) : request.http.body
        let config: CreateRequest
        do {
            config = try JSONDecoder().decode(CreateRequest.self, from: body)
        } catch {
            throw DockerAPIError.badParameter("invalid JSON in create request: \(error.localizedDescription)")
        }
        let existing = try await backend.listContainers(all: true)
        let name: String
        if let requested = request.query["name"], !requested.isEmpty {
            let trimmed = requested.hasPrefix("/") ? String(requested.dropFirst()) : requested
            guard ContainerNames.isValid(trimmed) else {
                throw DockerAPIError.badParameter("Invalid container name (\(requested)), only [a-zA-Z0-9][a-zA-Z0-9_.-] are allowed")
            }
            if let clash = existing.first(where: {
                DockerContainer.dockerName(for: $0) == trimmed || $0.id == ContainerNames.runtimeName(for: trimmed)
            }) {
                throw DockerAPIError(409, "Conflict. The container name \"/\(trimmed)\" is already in use by container \"\(DockerContainer.id(for: clash))\". You have to remove (or rename) that container to be able to reuse that name.")
            }
            name = trimmed
        } else {
            var candidate = ContainerNames.random()
            while existing.contains(where: { $0.id == candidate }) { candidate = ContainerNames.random() }
            name = candidate
        }

        // Docker creates only from local images; the client pulls on 404.
        guard let imageText = config.Image, let reference = ImageReference(imageText) else {
            throw DockerAPIError.badParameter("invalid reference format: \(config.Image ?? "")")
        }
        guard try await isLocal(reference, backend) else { throw DockerAPIError(404, "No such image: \(reference.familiar)") }

        let warnings = try await make(config, name: name, platform: request.query["platform"], backend, fillVolumes: true,
                                      dockerSocket: dockerSocket)
        await renames.remember(ContainerNames.runtimeName(for: name), Renames.Spec(body: body, platform: request.query["platform"]))
        let created = try await directory.resolve(name)
        return .json(CreateResponse(Id: created.id, Warnings: warnings), status: 201)
    }

    /// Whether the image is here, from the list of references (no sizes:
    /// listing those took a quarter of a second with some fifty images).
    private static func isLocal(_ reference: ImageReference, _ backend: DockerBackend) async throws -> Bool {
        try await backend.listImageReferences().contains { image in
            ImageReference(image.reference)?.canonical == reference.canonical
                || (reference.digest != nil && image.digest == reference.digest)
        }
    }

    /// Create `name` from a Docker create request; the warnings to pass on.
    private static func make(_ config: CreateRequest, name: String, platform: String?,
                             _ backend: DockerBackend, fillVolumes: Bool = false,
                             dockerSocket: String? = nil) async throws -> [String] {
        let (volumeSync, syncWarnings) = await volumeSyncModes(config, backend)
        var mapping = try CreateMapping.arguments(config, name: name, platform: platform,
                                                  dnsName: await serviceDNSName(config, backend),
                                                  dockerSocket: dockerSocket, volumeSync: volumeSync,
                                                  freePort: FreePort.pick)
        mapping.warnings += syncWarnings
        // Named volumes that don't exist yet: the runtime makes them with the
        // container, and Docker fills those from the image too (an empty
        // `pgdata` with lost+found would stop postgres's initdb).
        var missing: Set<String> = []
        let named = mapping.volumeMounts.map(\.name).filter { name in
            !mapping.anonymousVolumes.contains { $0.name == name }
        }
        if fillVolumes, !named.isEmpty, let volumes = try? await backend.listVolumes() {
            let present = Set(volumes.map(\.configuration.name))
            missing = Set(named.filter { !present.contains($0) })
        }
        var made: [String] = []
        do {
            for volume in mapping.anonymousVolumes {
                try await backend.createVolume(volume.name)
                made.append(volume.name)
            }
            try await engine { try await backend.createContainer(mapping.arguments) }
        } catch {
            for volume in made { try? await backend.deleteVolume(volume) }
            throw error
        }
        if fillVolumes {
            var fresh: [(name: String, path: String)] = []
            for mount in mapping.volumeMounts where await FreshVolumes.shared.take(mount.name)
                || missing.contains(mount.name)
                || mapping.anonymousVolumes.contains(where: { $0.name == mount.name }) {
                fresh.append(mount)
            }
            if !fresh.isEmpty {
                await FreshVolumes.copyUp(fresh, image: mapping.image, container: ContainerNames.runtimeName(for: name), backend: backend)
            }
        }
        return mapping.warnings
    }

    /// Sync modes of the named volumes this request mounts, when the CLI
    /// takes them; otherwise a warning for each that asked for one.
    static func volumeSyncModes(_ config: CreateRequest, _ backend: DockerBackend) async -> ([String: String], [String]) {
        let host = config.HostConfig
        let names = Set((host?.Binds ?? []).compactMap { $0.split(separator: ":").first.map(String.init) }
                        + (host?.Mounts ?? []).filter { ($0.Type ?? "volume").lowercased() == "volume" }.compactMap(\.Source))
        guard !names.isEmpty, let volumes = try? await backend.listVolumes() else { return ([:], []) }
        var modes: [String: String] = [:]
        for volume in volumes where names.contains(volume.name) {
            if let sync = volume.configuration.labels?[DockerLabels.volumeSync] { modes[volume.name] = sync }
        }
        guard !modes.isEmpty else { return ([:], []) }
        if await backend.supportsVolumeSync() { return (modes, []) }
        return ([:], modes.keys.sorted().map {
            "Volume \($0): sync=\(modes[$0]!) is ignored; this container CLI mounts volumes with fsync."
        })
    }

    // MARK: - Rename

    /// `container` can't rename. Compose renames only the container it just
    /// created (`<id>_<name>` → `<name>` when it recreates a service), before
    /// it ever starts: that one is made again under the new name from the
    /// request it was created with, and its old ID keeps finding it.
    static func rename(_ request: DockerRequest, _ directory: ContainerDirectory, _ backend: DockerBackend,
                       _ renames: Renames, dockerSocket: String? = nil) async throws -> HTTPResponse {
        guard var newName = request.query["name"], !newName.isEmpty else {
            throw DockerAPIError.badParameter("name is required")
        }
        if newName.hasPrefix("/") { newName.removeFirst() }
        guard ContainerNames.isValid(newName) else {
            throw DockerAPIError.badParameter("Invalid container name (\(newName)), only [a-zA-Z0-9][a-zA-Z0-9_.-] are allowed")
        }
        let item = try await directory.resolve(request.parameters["id"]!)
        if item.dockerName == newName { return .noContent }
        if let clash = try await backend.listContainers(all: true).first(where: {
            DockerContainer.dockerName(for: $0) == newName || $0.id == ContainerNames.runtimeName(for: newName)
        }) {
            throw DockerAPIError(409, "Conflict. The container name \"/\(newName)\" is already in use by container \"\(DockerContainer.id(for: clash))\". You have to remove (or rename) that container to be able to reuse that name.")
        }
        guard item.state == .created, let spec = await renames.spec(item.name) else {
            throw DockerAPIError(409, "Error when allocating new name: Irekobox can rename a container only before it first starts, when it was created through this Docker API")
        }
        let config = try JSONDecoder().decode(CreateRequest.self, from: spec.body)
        _ = try await make(config, name: newName, platform: spec.platform, backend, dockerSocket: dockerSocket)
        try await engine { try await backend.deleteContainer(item.name, force: false) }
        if let volumes = item.container.configuration.labels[DockerLabels.anonymousVolumes] {
            for volume in volumes.split(separator: ",") { try? await backend.deleteVolume(String(volume)) }
        }
        await renames.moved(item.name, id: item.id, to: ContainerNames.runtimeName(for: newName), spec)
        return .noContent
    }

    // MARK: - List

    static func list(_ request: DockerRequest, _ directory: ContainerDirectory) async throws -> HTTPResponse {
        let filters = try DockerFilters(query: request.query["filters"])
        try filters.validate(listFilters)
        // `all` or any status filter shows every state; otherwise running only.
        let showAll = request.bool("all") || !filters["status"].isEmpty
        var items = try await directory.all().filter { showAll || $0.state == .running }
        items = items.filter { matches($0, filters) }
        if let limit = try request.int("limit"), limit > 0 { items = Array(items.prefix(limit)) }
        let now = Date()
        return .json(items.map { ContainerModels.summary($0, now: now) })
    }

    static func matches(_ item: DockerContainer, _ filters: DockerFilters) -> Bool {
        let container = item.container
        if !filters["status"].isEmpty && !filters["status"].contains(item.state.rawValue) { return false }
        if !filters["health"].isEmpty && !filters["health"].contains(item.health?.status.rawValue ?? "none") { return false }
        if !filters.matchesLabels(container.configuration.labels) { return false }
        if !filters["name"].isEmpty && !filters["name"].contains(where: { pattern in
            let name = item.dockerName
            if let regex = try? Regex(pattern) { return name.contains(regex) || "/\(name)".contains(regex) }
            return name.contains(pattern)
        }) { return false }
        if !filters["id"].isEmpty && !filters["id"].contains(where: { item.id.hasPrefix($0.lowercased()) }) { return false }
        if !filters["ancestor"].isEmpty {
            let reference = container.configuration.image.reference
            let familiar = ContainerModels.familiar(reference)
            let digest = container.configuration.image.descriptor.digest
            guard filters["ancestor"].contains(where: { value in
                value == reference || value == familiar || value == digest
                    || familiar.hasPrefix(value + ":") || reference.hasPrefix(value + ":")
            }) else { return false }
        }
        if !filters["network"].isEmpty
            && !filters["network"].contains(where: { name in container.configuration.networks.contains { $0.network == name } }) {
            return false
        }
        if !filters["volume"].isEmpty && !filters["volume"].contains(where: { value in
            (container.configuration.mounts ?? []).contains { $0.volumeName == value || $0.destination == value }
        }) { return false }
        if !filters["exited"].isEmpty {
            guard item.state == .exited, let code = item.exit?.code,
                  filters["exited"].contains(String(code)) else { return false }
        }
        if !filters["publish"].isEmpty && !filters["publish"].contains(where: { value in
            let port = value.split(separator: "/").first.map(String.init) ?? value
            return ContainerModels.ports(container).contains { $0.PublicPort.map(String.init) == port }
        }) { return false }
        return true
    }

    // MARK: - Prune

    struct PruneReport: Encodable {
        let ContainersDeleted: [String]?
        let SpaceReclaimed: Int64
    }

    static func prune(_ request: DockerRequest, _ directory: ContainerDirectory, _ backend: DockerBackend) async throws -> HTTPResponse {
        let filters = try DockerFilters(query: request.query["filters"])
        try filters.validate(["label", "until"])
        let cutoff: Date? = try filters["until"].first.map { value in
            if let seconds = TimeInterval(value) { return Date(timeIntervalSince1970: seconds) }
            if let date = DockerTime.parse(value) { return date }
            throw DockerAPIError.badParameter("invalid until filter: \(value)")
        }
        var deleted: [String] = []
        for item in try await directory.all() where item.state != .running {
            guard filters.matchesLabels(item.container.configuration.labels) else { continue }
            if let cutoff, let created = DockerTime.parse(item.container.configuration.creationDate), created >= cutoff {
                continue
            }
            do {
                try await backend.deleteContainer(item.name, force: false)
                deleted.append(item.id)
            } catch {
                continue    // in use or gone: Docker skips those too
            }
        }
        return .json(PruneReport(ContainersDeleted: deleted.isEmpty ? nil : deleted, SpaceReclaimed: 0))
    }

    // MARK: - Wait

    struct WaitResponse: Encodable {
        struct WaitError: Encodable { let Message: String }
        let StatusCode: Int64
        let Error: WaitError?
    }

    /// Headers go out at once (clients register the wait before `start`), the
    /// body when the condition is met.
    static func wait(_ request: DockerRequest, _ directory: ContainerDirectory, _ backend: DockerBackend,
                     _ waits: ExitWaits? = nil) async throws -> HTTPResponse {
        let condition = request.query["condition"] ?? "not-running"
        guard ["not-running", "next-exit", "removed"].contains(condition) else {
            throw DockerAPIError.badParameter("invalid condition: \"\(condition)\"")
        }
        let item = try await directory.resolve(request.parameters["id"]!)
        let name = item.name
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let task = Task {
            let result: WaitResponse
            do {
                let code = try await waitFor(condition, name: name, initial: item, directory: directory,
                                             backend: backend, waits: waits)
                result = WaitResponse(StatusCode: Int64(code), Error: nil)
            } catch is CancellationError {
                continuation.finish()
                return
            } catch {
                result = WaitResponse(StatusCode: -1, Error: .init(Message: error.localizedDescription))
            }
            let data = (try? JSONEncoder().encode(result)) ?? Data()
            continuation.yield(data + Data("\n".utf8))
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: .stream(stream))
    }

    static func waitFor(_ condition: String, name: String, initial: DockerContainer,
                        directory: ContainerDirectory, backend: DockerBackend, waits: ExitWaits? = nil) async throws -> Int32 {
        var current = initial
        if condition == "not-running", current.state != .running {
            return current.exit?.code ?? 0
        }
        // Waiting for a run that hasn't started: let `start` catch its exit.
        if current.state != .running, let waits {
            await waits.expect(name)
            defer { Task { await waits.done(name) } }
            while true {
                if let run = await waits.run(name) {
                    let exit = await run.value
                    if condition == "removed" {
                        while (try? await directory.resolve(name)) != nil {
                            try await Task.sleep(for: .milliseconds(50))
                        }
                    }
                    if let exit { return exit.code }
                    break   // the runtime wait failed: fall back to polling
                }
                try await Task.sleep(for: .milliseconds(50))
                guard (try? await directory.resolve(name)) != nil else {
                    // Removed before it ran (a --rm whose start failed).
                    if condition == "removed" { return current.exit?.code ?? 0 }
                    throw DockerAPIError.noSuchContainer(name)
                }
                if Task.isCancelled { throw CancellationError() }
            }
            current = (try? await directory.resolve(name)) ?? current
            if current.state != .running { return current.exit?.code ?? 0 }
        }
        // next-exit / removed on a container that isn't running yet: wait for
        // it to start (docker run sends wait before start).
        while current.state != .running {
            try await Task.sleep(for: .milliseconds(200))
            guard let refreshed = try? await directory.resolve(name) else {
                if condition == "removed" { return current.exit?.code ?? 0 }
                throw DockerAPIError.noSuchContainer(name)
            }
            if refreshed.state == .exited, condition != "removed",
               refreshed.exit?.exitedAt != current.exit?.exitedAt {
                return refreshed.exit?.code ?? 0   // ran and exited between polls
            }
            current = refreshed
        }
        let exit = try await backend.waitContainer(name)
        if let exits = directory.exits, let container = try? await backend.listContainers(all: true).first(where: { $0.id == name }) {
            await exits.record(exit, for: container)
        }
        if condition == "removed" {
            while (try? await directory.resolve(name)) != nil {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        return exit.code
    }

    /// `web.shop.<domain>` for a compose service, when a local domain is set
    /// and no other container holds that name (aliases are unique in the
    /// runtime: a duplicate would fail the create).
    static func serviceDNSName(_ config: CreateRequest, _ backend: DockerBackend) async -> String? {
        guard let labels = config.Labels, let service = labels["com.docker.compose.service"],
              let project = labels["com.docker.compose.project"],
              let properties = try? await backend.systemProperties(),
              let domain = LocalDomain.parse(properties: properties),
              let name = LocalDomain.serviceName(service: service, project: project, domain: domain) else { return nil }
        let taken = (try? await backend.listContainers(all: true))?.contains { container in
            container.configuration.networks.contains { $0.options?.aliases?.contains(name) == true }
        } ?? true
        return taken ? nil : name
    }

    /// Engine failures become 500s with the engine's message; a missing
    /// container is 404.
    static func engine(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let error as DockerAPIError {
            throw error
        } catch EngineError.notFound(let what) {
            throw DockerAPIError(404, "No such container: \(what)")
        } catch {
            throw DockerAPIError(500, error.localizedDescription)
        }
    }
}

/// Exits that someone is waiting for (`docker run` asks for `wait` before
/// `start`). A process that ends at once — and with `--rm` is removed at
/// once — can't be caught by polling, so `start` boots the VM, begins the
/// runtime wait, and only then starts the process.
public actor ExitWaits {
    private var expected: [String: Int] = [:]
    private var runs: [String: Task<ContainerExit?, Never>] = [:]

    public init() {}

    func expect(_ name: String) { expected[name, default: 0] += 1 }

    func done(_ name: String) {
        expected[name] = (expected[name] ?? 1) - 1
        if expected[name] == 0 {
            expected[name] = nil
            runs[name] = nil
        }
    }

    func isExpected(_ name: String) -> Bool { expected[name] != nil }

    /// Begin the runtime wait for the run about to start.
    func begin(_ name: String, backend: DockerBackend) {
        runs[name] = Task { try? await backend.waitContainer(name) }
    }

    func run(_ name: String) -> Task<ContainerExit?, Never>? { runs[name] }
}
