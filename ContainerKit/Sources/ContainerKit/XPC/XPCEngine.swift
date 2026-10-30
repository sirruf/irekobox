import Foundation

/// ``ContainerEngine`` that talks to `container-apiserver` over XPC for reads
/// and simple lifecycle calls (~30× faster than spawning the CLI), and delegates
/// everything else to a ``CLIEngine``: `start` (needs stdio bootstrap), images
/// (a private helper service without compatibility guarantees), builds,
/// registries, system start/stop, and creates/prunes.
public struct XPCEngine: ContainerEngine {
    private let connection: APIServerConnection
    /// Handles every operation XPC doesn't cover.
    public let fallback: CLIEngine
    /// Runs before every start; throwing stops it (the app checks ports here).
    public var beforeStart: (@Sendable (String) async throws -> Void)?

    public init(fallback: CLIEngine) {
        self.connection = APIServerConnection()
        self.fallback = fallback
    }

    init(connection: APIServerConnection, fallback: CLIEngine) {
        self.connection = connection
        self.fallback = fallback
    }

    private static let decoder = JSONDecoder()

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw EngineError.decoding(String(describing: error))
        }
    }

    private func payload(_ reply: APIServerConnection.Reply, _ key: String) throws -> Data {
        guard let data = reply.data(key) else {
            throw EngineError.decoding("apiserver reply has no `\(key)`")
        }
        return data
    }

    // MARK: System

    public func systemStatus() async throws -> SystemStatus? { try await fallback.systemStatus() }
    public func startServices() async throws { try await fallback.startServices() }
    public func stopServices() async throws { try await fallback.stopServices() }
    public func systemProperties() async throws -> String { try await fallback.systemProperties() }
    public func systemLogs(last: String) async throws -> String { try await fallback.systemLogs(last: last) }

    public func diskUsage() async throws -> SystemDiskUsage {
        let reply = try await connection.send(.init(route: "systemDiskUsage"))
        return try decode(SystemDiskUsage.self, try XPCPayload.normalizingDates(payload(reply, "diskUsageStats")))
    }

    public func builderStatus() async throws -> BuilderStatus { try await fallback.builderStatus() }

    // MARK: Containers

    public func listContainers(all: Bool) async throws -> [Container] {
        let containers = try await snapshots(ids: [])
        return all ? containers : containers.filter { $0.state.isRunning }
    }

    public func inspectContainer(_ id: String) async throws -> Container {
        guard let container = try await snapshots(ids: [id]).first else {
            throw EngineError.notFound("Container \(id) not found.")
        }
        return container
    }

    private func snapshots(ids: [String]) async throws -> [Container] {
        let request = APIServerConnection.Request(route: "containerList")
        let filters = try JSONSerialization.data(withJSONObject: ["ids": ids, "labels": [String: String]()])
        request.set("listFilters", filters)
        let reply = try await connection.send(request)
        guard let data = reply.data("containers") else { return [] }
        return try decode([Container].self, try XPCPayload.containers(data))
    }

    public func startContainer(_ id: String) async throws {
        try await beforeStart?(id)
        try await fallback.startContainer(id)
    }

    public func stopContainer(_ id: String, timeout: Int32?, signal: String?) async throws {
        struct StopOptions: Encodable {
            let timeoutInSeconds: Int32
            let signal: String?
        }
        let grace = timeout ?? 5
        let request = APIServerConnection.Request(route: "containerStop")
        request.set("id", id)
        request.set("stopOptions", try JSONEncoder().encode(StopOptions(timeoutInSeconds: grace, signal: signal)))
        // Stopping waits for the in-guest grace period before replying.
        _ = try await connection.send(request, timeout: .seconds(Int(grace) + 55))
    }

    public func killContainer(_ id: String, signal: String?) async throws {
        let request = APIServerConnection.Request(route: "containerKill")
        request.set("id", id)
        request.set("processIdentifier", id)
        request.set("signal", signal ?? "KILL")
        _ = try await connection.send(request)
    }

    public func deleteContainer(_ id: String, force: Bool) async throws {
        let request = APIServerConnection.Request(route: "containerDelete")
        request.set("id", id)
        request.set("forceDelete", force)
        _ = try await connection.send(request, timeout: .seconds(60))
    }

    public func pruneContainers() async throws { try await fallback.pruneContainers() }
    public func runContainer(_ arguments: [String]) async throws { try await fallback.runContainer(arguments) }
    public func createContainer(_ arguments: [String]) async throws { try await fallback.createContainer(arguments) }

    public func execute(_ id: String, command: [String]) async throws -> Data {
        try await fallback.execute(id, command: command)
    }

    public func inspectImage(_ reference: String) async throws -> ImageDetails { try await fallback.inspectImage(reference) }
    public func tagImage(_ source: String, as target: String) async throws { try await fallback.tagImage(source, as: target) }
    public func saveImages(_ references: [String], platform: String?, to path: String) async throws {
        try await fallback.saveImages(references, platform: platform, to: path)
    }
    public func loadImages(from path: String) async throws -> String { try await fallback.loadImages(from: path) }

    public func copy(from source: String, to destination: String) async throws {
        try await fallback.copy(from: source, to: destination)
    }

    public func exportContainer(_ id: String, to path: String) async throws {
        try await fallback.exportContainer(id, to: path)
    }

    public func recreateContainer(_ container: Container, edits: ContainerEdits) async throws {
        try await fallback.recreateContainer(container, edits: edits)
    }

    /// Wait for the container's init process to exit and return its code.
    /// No timeout: it blocks as long as the container runs.
    public func waitContainer(_ id: String) async throws -> ContainerExit {
        try await waitProcess(id, process: id)
    }

    public func waitProcess(_ container: String, process: String) async throws -> ContainerExit {
        let request = APIServerConnection.Request(route: "containerWait")
        request.set("id", container)
        request.set("processIdentifier", process)
        let reply = try await connection.send(request, timeout: nil)
        return ContainerExit(code: Int32(truncatingIfNeeded: reply.int64("exitCode")),
                             exitedAt: reply.date("exitedAt"))
    }

    private static func attach(_ stdio: ProcessStdio, to request: APIServerConnection.Request) {
        if let fd = stdio.stdin { request.set("stdin", fileDescriptor: fd) }
        if let fd = stdio.stdout { request.set("stdout", fileDescriptor: fd) }
        if let fd = stdio.stderr { request.set("stderr", fileDescriptor: fd) }
    }

    public func bootstrapContainer(_ id: String, stdio: ProcessStdio) async throws {
        let request = APIServerConnection.Request(route: "containerBootstrap")
        request.set("id", id)
        request.set("dynamicEnv", Data("{}".utf8))
        Self.attach(stdio, to: request)
        _ = try await connection.send(request, timeout: .seconds(120))
    }

    public func createProcess(_ container: String, process: String, spec: ProcessSpec, stdio: ProcessStdio) async throws {
        let request = APIServerConnection.Request(route: "containerCreateProcess")
        request.set("id", container)
        request.set("processIdentifier", process)
        request.set("processConfig", try JSONEncoder().encode(spec))
        Self.attach(stdio, to: request)
        _ = try await connection.send(request, timeout: .seconds(60))
    }

    public func startProcess(_ container: String, process: String) async throws {
        let request = APIServerConnection.Request(route: "containerStartProcess")
        request.set("id", container)
        request.set("processIdentifier", process)
        _ = try await connection.send(request, timeout: .seconds(60))
    }

    public func resizeProcess(_ container: String, process: String, width: Int, height: Int) async throws {
        let request = APIServerConnection.Request(route: "containerResize")
        request.set("id", container)
        request.set("processIdentifier", process)
        request.set("width", UInt64(max(1, width)))
        request.set("height", UInt64(max(1, height)))
        _ = try await connection.send(request)
    }

    public func containerStats(_ id: String) async throws -> ContainerStats {
        let request = APIServerConnection.Request(route: "containerStats")
        request.set("id", id)
        let reply = try await connection.send(request)
        return try decode(ContainerStats.self, try payload(reply, "statistics"))
    }

    public func containerLogs(_ id: String, follow: Bool) -> AsyncThrowingStream<String, Error> {
        let connection = self.connection
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = APIServerConnection.Request(route: "containerLogs")
                    request.set("id", id)
                    let reply = try await connection.send(request)
                    // [0] is the container's output; [1] is the VM boot log.
                    guard let handle = reply.fileHandles("logs").first else {
                        throw EngineError.decoding("apiserver returned no log file")
                    }
                    for try await line in LogFileStream.lines(of: handle, follow: follow) {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch EngineError.cancelled {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Images

    public func listImages() async throws -> [ContainerImage] { try await fallback.listImages() }
    public func pullImage(_ reference: String) async throws { try await fallback.pullImage(reference) }
    public func deleteImage(_ reference: String, force: Bool) async throws {
        try await fallback.deleteImage(reference, force: force)
    }
    public func pruneImages(all: Bool) async throws { try await fallback.pruneImages(all: all) }
    public func pullImageWithProgress(_ reference: String, platform: String?) -> AsyncThrowingStream<String, Error> {
        fallback.pullImageWithProgress(reference, platform: platform)
    }
    public func buildImage(_ options: BuildOptions) -> AsyncThrowingStream<String, Error> { fallback.buildImage(options) }
    public func pushImage(_ reference: String) -> AsyncThrowingStream<String, Error> { fallback.pushImage(reference) }

    // MARK: Volumes

    public func listVolumes() async throws -> [Volume] {
        let reply = try await connection.send(.init(route: "volumeList"))
        guard let data = reply.data("volumes") else { return [] }
        return try decode([Volume].self, try XPCPayload.volumes(data))
    }

    public func createVolume(_ name: String) async throws { try await fallback.createVolume(name) }
    public func createVolume(_ name: String, labels: [String: String], size: String?, options: [String: String]) async throws {
        try await fallback.createVolume(name, labels: labels, size: size, options: options)
    }
    public func createNetwork(_ spec: NetworkSpec) async throws { try await fallback.createNetwork(spec) }

    public func volumeDiskUsage(_ name: String) async throws -> Int64 {
        let request = APIServerConnection.Request(route: "volumeDiskUsage")
        request.set("volumeName", name)
        let reply = try await connection.send(request)
        return Int64(clamping: reply.uint64("volumeSize"))
    }
    public func deleteVolume(_ name: String) async throws { try await fallback.deleteVolume(name) }
    public func pruneVolumes() async throws { try await fallback.pruneVolumes() }

    // MARK: Networks

    public func listNetworks() async throws -> [Network] {
        let reply = try await connection.send(.init(route: "networkList"))
        guard let data = reply.data("networkResources") else { return [] }
        return try decode([Network].self, try XPCPayload.normalizingDates(data))
    }

    public func createNetwork(_ name: String, subnet: String?) async throws {
        try await fallback.createNetwork(name, subnet: subnet)
    }
    public func deleteNetwork(_ name: String) async throws { try await fallback.deleteNetwork(name) }
    public func pruneNetworks() async throws { try await fallback.pruneNetworks() }

    // MARK: Registries

    public func listRegistryLogins() async throws -> [RegistryLogin] { try await fallback.listRegistryLogins() }
    public func registryLogin(server: String, username: String, password: String,
                              scheme: RegistryScheme) async throws {
        try await fallback.registryLogin(server: server, username: username, password: password, scheme: scheme)
    }
    public func registryLogout(server: String) async throws { try await fallback.registryLogout(server: server) }
}
