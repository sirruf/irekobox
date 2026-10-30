import Foundation
import ContainerKit

/// Image endpoints: pull, list, inspect, history, tag, remove, prune,
/// save/load, push and Docker Hub search. Push uses `container`'s own
/// registry logins (Keychain); X-Registry-Auth from clients isn't applied.
public enum ImagesAPI {
    /// Docker Hub search, replaceable in tests.
    public typealias Search = @Sendable (_ term: String, _ limit: Int) async throws -> [SearchResult]

    public static func register(on router: inout DockerRouter, backend: DockerBackend,
                                search: @escaping Search = DockerHubSearch.search) {
        let directory = ImageDirectory(backend: backend)
        router.add("POST", "/images/create") { request in
            await respond { try pull(request, backend) }
        }
        router.add("GET", "/images/json") { request in
            await respond { try await list(request, directory, backend) }
        }
        router.add("GET", "/images/{name*}/json") { request in
            await respond { try await inspect(request.parameters["name"]!, directory, backend) }
        }
        router.add("GET", "/images/{name*}/history") { request in
            await respond { try await history(request.parameters["name"]!, directory, backend) }
        }
        router.add("POST", "/images/{name*}/tag") { request in
            await respond { try await tag(request, directory, backend) }
        }
        router.add("DELETE", "/images/{name*}") { request in
            await respond { try await remove(request, directory, backend) }
        }
        router.add("POST", "/images/prune") { request in
            await respond { try await prune(request, directory, backend) }
        }
        router.add("GET", "/images/{name*}/get") { request in
            await respond { try await save([request.parameters["name"]!], request, directory, backend) }
        }
        router.add("GET", "/images/get") { request in
            await respond { try await save(request.http.queryValues("names"), request, directory, backend) }
        }
        router.add("POST", "/images/load") { request in
            await respond { try await load(request, backend) }
        }
        router.add("POST", "/images/{name*}/push") { request in
            await respond { try await push(request, directory, backend) }
        }
        router.add("GET", "/images/search") { request in
            await respond {
                guard let term = request.query["term"], !term.isEmpty else { throw DockerAPIError.badParameter("term is required") }
                let filters = try DockerFilters(query: request.query["filters"])
                try filters.validate(["is-official", "is-automated", "stars"])
                var results = try await search(term, min(100, max(1, try request.int("limit") ?? 25)))
                if let official = filters["is-official"].first { results = results.filter { $0.is_official == (official == "true") } }
                if let stars = filters["stars"].first.flatMap(Int.init) { results = results.filter { $0.star_count >= stars } }
                return .json(results)
            }
        }
    }

    // MARK: - List / inspect / history

    struct Summary: Encodable {
        let Id: String
        let ParentId = ""
        let RepoTags: [String]
        let RepoDigests: [String]
        let Created: Int64
        let Size: Int
        let SharedSize = -1
        let VirtualSize: Int
        let Labels: [String: String]
        let Containers = -1
    }

    static func list(_ request: DockerRequest, _ directory: ImageDirectory, _ backend: DockerBackend) async throws -> HTTPResponse {
        let filters = try DockerFilters(query: request.query["filters"])
        try filters.validate(["dangling", "label", "reference", "before", "since"])
        // Every image here has a name: none is dangling.
        if filters["dangling"].contains("true") { return .json([Summary]()) }
        var images = try await directory.all()
        if !filters["reference"].isEmpty {
            images = images.filter { image in
                filters["reference"].contains { pattern in
                    image.repoTags.contains { matches(pattern, $0) }
                        || image.references.contains { matches(pattern, $0.reference) }
                }
            }
        }
        let labels = await withTaskGroup(of: (String, [String: String]).self) { group in
            for image in images {
                group.addTask {
                    let details = try? await backend.inspectImage(image.primary.reference)
                    return (image.id, details?.variant()?.config?.config?.Labels ?? [:])
                }
            }
            var result: [String: [String: String]] = [:]
            for await (id, value) in group { result[id] = value }
            return result
        }
        images = images.filter { filters.matchesLabels(labels[$0.id] ?? [:]) }
        // With a reference filter, Docker lists only the tags that match.
        let references = filters["reference"]
        return .json(images.map { image in
            let tags = references.isEmpty ? image.repoTags
                : image.repoTags.filter { tag in references.contains { matches($0, tag) } }
            return Summary(Id: image.id, RepoTags: tags, RepoDigests: image.repoDigests,
                    Created: Int64(image.created?.timeIntervalSince1970 ?? 0), Size: image.size,
                    VirtualSize: image.size, Labels: labels[image.id] ?? [:])
        })
    }

    /// Docker's `reference` filter: a glob over `repo:tag` (a bare repo
    /// matches any of its tags).
    static func matches(_ pattern: String, _ name: String) -> Bool {
        let target = pattern.contains(":") ? name : String(name.split(separator: ":").first ?? "")
        return fnmatch(pattern, target, 0) == 0
    }

    struct Inspect: Encodable {
        struct Config: Encodable {
            let Hostname = ""
            let User: String
            let Env: [String]
            let Cmd: [String]?
            let Entrypoint: [String]?
            let WorkingDir: String
            let ExposedPorts: [String: [String: String]]?
            let Volumes: [String: [String: String]]?
            let Labels: [String: String]?
            let StopSignal: String?
        }
        struct RootFS: Encodable {
            let `Type`: String
            let Layers: [String]
        }
        struct Metadata: Encodable { let LastTagTime = DockerTime.zero }
        let Id: String
        let RepoTags: [String]
        let RepoDigests: [String]
        let Parent = ""
        let Comment = ""
        let Created: String
        let DockerVersion = ""
        let Author: String
        let Config: Config
        let Architecture: String
        let Os: String
        let Size: Int
        let VirtualSize: Int
        let RootFS: RootFS
        let Metadata = Metadata()
    }

    static func inspect(_ name: String, _ directory: ImageDirectory, _ backend: DockerBackend) async throws -> HTTPResponse {
        let (image, _) = try await directory.resolve(name)
        let details = try await backend.inspectImage(image.primary.reference)
        let variant = details.variant()
        let oci = variant?.config
        let process = oci?.config
        return .json(Inspect(
            Id: image.id, RepoTags: image.repoTags, RepoDigests: image.repoDigests,
            Created: oci?.created ?? image.primary.configuration.creationDate ?? DockerTime.zero,
            Author: oci?.author ?? "",
            Config: .init(User: process?.User ?? "", Env: process?.Env ?? [], Cmd: process?.Cmd,
                          Entrypoint: process?.Entrypoint, WorkingDir: process?.WorkingDir ?? "",
                          ExposedPorts: process?.ExposedPorts, Volumes: process?.Volumes,
                          Labels: process?.Labels, StopSignal: process?.StopSignal),
            Architecture: variant?.platform?.architecture ?? oci?.architecture ?? "arm64",
            Os: variant?.platform?.os ?? oci?.os ?? "linux",
            Size: variant?.size ?? image.size, VirtualSize: variant?.size ?? image.size,
            RootFS: .init(Type: oci?.rootfs?.type ?? "layers", Layers: oci?.rootfs?.diff_ids ?? [])))
    }

    struct HistoryEntry: Encodable {
        let Id: String
        let Created: Int64
        let CreatedBy: String
        let Tags: [String]?
        let Size = 0
        let Comment: String
    }

    static func history(_ name: String, _ directory: ImageDirectory, _ backend: DockerBackend) async throws -> HTTPResponse {
        let (image, _) = try await directory.resolve(name)
        let details = try await backend.inspectImage(image.primary.reference)
        let entries = (details.variant()?.config?.history ?? []).reversed()
        return .json(entries.enumerated().map { index, entry in
            HistoryEntry(Id: index == 0 ? image.id : "<missing>",
                         Created: Int64(entry.created.flatMap(DockerTime.parse)?.timeIntervalSince1970 ?? 0),
                         CreatedBy: entry.created_by ?? "", Tags: index == 0 ? image.repoTags : nil,
                         Comment: entry.comment ?? "")
        })
    }

    // MARK: - Tag / remove / prune

    static func tag(_ request: DockerRequest, _ directory: ImageDirectory, _ backend: DockerBackend) async throws -> HTTPResponse {
        let (image, matched) = try await directory.resolve(request.parameters["name"]!)
        guard let repo = request.query["repo"], !repo.isEmpty else { throw DockerAPIError.badParameter("repo is required") }
        let tag = request.query["tag"].flatMap { $0.isEmpty ? nil : $0 } ?? "latest"
        guard let target = ImageReference("\(repo):\(tag)") else {
            throw DockerAPIError.badParameter("invalid reference format: \(repo):\(tag)")
        }
        try await ContainersAPI.engine {
            try await backend.tagImage((matched ?? image.primary).reference, as: target.canonical)
        }
        return HTTPResponse(status: 201)
    }

    struct DeleteItem: Encodable {
        var Untagged: String?
        var Deleted: String?
    }

    static func remove(_ request: DockerRequest, _ directory: ImageDirectory, _ backend: DockerBackend) async throws -> HTTPResponse {
        let name = request.parameters["name"]!
        let force = request.bool("force")
        let (image, matched) = try await directory.resolve(name)
        // By ID with several tags: Docker wants force.
        if matched == nil, image.references.count > 1, !force {
            throw DockerAPIError(409, "conflict: unable to delete \(image.id.dropFirst(7).prefix(12)) (must be forced) - image is referenced in multiple repositories")
        }
        let targets = matched.map { [$0] } ?? image.references
        let lastReference = targets.count == image.references.count
        if lastReference && !force {
            let containers = try await backend.listContainers(all: true)
            if let user = containers.first(where: { container in
                container.configuration.image.descriptor.digest == image.primary.digest
                    || targets.contains { $0.reference == container.configuration.image.reference }
            }) {
                throw DockerAPIError(409, "conflict: unable to remove repository reference \"\(name)\" (must force) - container \(DockerContainer.id(for: user).prefix(12)) is using its referenced image \(image.id.dropFirst(7).prefix(12))")
            }
        }
        var report: [DeleteItem] = []
        for target in targets {
            try await ContainersAPI.engine { try await backend.deleteImage(target.reference, force: force) }
            report.append(DeleteItem(Untagged: ImageReference(target.reference)?.familiar ?? target.reference))
        }
        if lastReference { report.append(DeleteItem(Deleted: image.id)) }
        return .json(report)
    }

    struct PruneReport: Encodable {
        let ImagesDeleted: [DeleteItem]?
        let SpaceReclaimed: Int
    }

    static func prune(_ request: DockerRequest, _ directory: ImageDirectory, _ backend: DockerBackend) async throws -> HTTPResponse {
        let filters = try DockerFilters(query: request.query["filters"])
        try filters.validate(["dangling"])
        // Our images all have names, so a dangling-only prune has nothing to do.
        let all = filters["dangling"].contains("false") || filters["dangling"].contains("0")
        guard all else { return .json(PruneReport(ImagesDeleted: nil, SpaceReclaimed: 0)) }
        let before = try await directory.all()
        try await ContainersAPI.engine { try await backend.pruneImages(all: true) }
        let remaining = Set(try await directory.all().map(\.id))
        let removed = before.filter { !remaining.contains($0.id) }
        let items = removed.flatMap { image in
            image.repoTags.map { DeleteItem(Untagged: $0) } + [DeleteItem(Deleted: image.id)]
        }
        return .json(PruneReport(ImagesDeleted: items.isEmpty ? nil : items,
                                 SpaceReclaimed: removed.map(\.size).reduce(0, +)))
    }

    // MARK: - Save / load

    static func save(_ names: [String], _ request: DockerRequest, _ directory: ImageDirectory,
                     _ backend: DockerBackend) async throws -> HTTPResponse {
        guard !names.isEmpty else { throw DockerAPIError.badParameter("no images to save") }
        var references: [String] = []
        for name in names {
            let (image, matched) = try await directory.resolve(name)
            references.append((matched ?? image.primary).reference)
        }
        let folder = try ArchiveAPI.scratch()
        let file = folder.appending(path: "images.tar")
        do {
            // The native platform unless asked: images are pulled for it only,
            // and saving every variant fails on the ones that aren't local.
            let platform = request.query["platform"].flatMap { $0.isEmpty ? nil : $0 } ?? "linux/arm64"
            try await backend.saveImages(references, platform: platform, to: file.path)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw DockerAPIError(500, "save failed: \(error.localizedDescription)")
        }
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/x-tar")],
                            body: .stream(Tar.read(file) { try? FileManager.default.removeItem(at: folder) }))
    }

    static func load(_ request: DockerRequest, _ backend: DockerBackend) async throws -> HTTPResponse {
        let folder = try ArchiveAPI.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "load.tar")
        try request.http.saveBody(to: file)
        let output: String
        do {
            output = try await backend.loadImages(from: file.path)
        } catch {
            throw DockerAPIError(500, "load failed (Docker archives must be OCI compatible): \(error.localizedDescription)")
        }
        let lines = output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let body = lines.map { line -> Data in
            // The CLI lists loaded references; docker prints "Loaded image: x".
            let text = ImageReference(line).map { "Loaded image: \($0.familiar)" } ?? line
            return (try? JSONEncoder().encode(["stream": text + "\n"])).map { $0 + Data("\n".utf8) } ?? Data()
        }.reduce(Data(), +)
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: .data(body))
    }

    // MARK: - Push

    static func push(_ request: DockerRequest, _ directory: ImageDirectory, _ backend: DockerBackend) async throws -> HTTPResponse {
        let name = request.parameters["name"]!
        let tag = request.query["tag"].flatMap { $0.isEmpty ? nil : $0 }
        let text = tag.map { name.contains("@") ? name : "\(name):\($0)" } ?? name
        guard let reference = ImageReference(text) else { throw DockerAPIError.badParameter("invalid reference format: \(text)") }
        _ = try await directory.resolve(reference.canonical)
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let task = Task {
            func send(_ progress: Progress) {
                if let data = try? JSONEncoder().encode(progress) { continuation.yield(data + Data("\n".utf8)) }
            }
            let repository = reference.registry == "docker.io" ? "docker.io/\(reference.repository)"
                : "\(reference.registry)/\(reference.repository)"
            send(Progress(status: "The push refers to repository [\(repository)]"))
            do {
                var lastPhase = ""
                for try await line in backend.pushImage(reference.canonical) {
                    let text = line.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty, text != lastPhase else { continue }
                    lastPhase = text
                    send(Progress(status: text, id: reference.tag ?? "latest"))
                }
                send(Progress(status: "\(reference.tag ?? "latest"): pushed"))
            } catch {
                let message = error.localizedDescription
                send(Progress(errorDetail: .init(message: message), error: message))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: .stream(stream))
    }

    struct Progress: Encodable {
        struct Detail: Encodable {
            let current: Int?
            let total: Int?
        }
        struct ErrorDetail: Encodable { let message: String }
        var status: String?
        var progressDetail: Detail?
        var id: String?
        var errorDetail: ErrorDetail?
        var error: String?
    }

    /// `POST /images/create?fromImage=alpine&tag=latest[&platform=]`: progress as
    /// one JSON object per line, errors in-stream (the status is already 200).
    static func pull(_ request: DockerRequest, _ backend: DockerBackend) throws -> HTTPResponse {
        if let source = request.query["fromSrc"], !source.isEmpty {
            throw DockerAPIError(501, "importing images (fromSrc) is not supported by Irekobox")
        }
        guard let from = request.query["fromImage"], !from.isEmpty else {
            throw DockerAPIError.badParameter("fromImage is required")
        }
        let tag = request.query["tag"] ?? ""
        let text = tag.isEmpty || from.contains("@") ? from : (tag.hasPrefix("sha256:") ? "\(from)@\(tag)" : "\(from):\(tag)")
        guard let reference = ImageReference(text) else {
            throw DockerAPIError.badParameter("invalid reference format: \(text)")
        }
        // Native architecture unless asked: a plain `image pull` would unpack
        // every platform of a multi-arch image. An image without an arm64
        // variant falls back to amd64, which runs under Rosetta, as Docker
        // on Apple silicon does.
        let requested = request.query["platform"].flatMap { $0.isEmpty ? nil : $0 }
        let platforms = requested.map { [$0] } ?? ["linux/arm64", "linux/amd64"]
        let label = reference.tag ?? reference.digest ?? "latest"
        // Docker prints "Pulling from library/alpine" (or "ghcr.io/x/y").
        let repository = reference.registry == "docker.io" ? reference.repository
            : "\(reference.registry)/\(reference.repository)"

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let task = Task {
            func send(_ progress: Progress) {
                if let data = try? JSONEncoder().encode(progress) { continuation.yield(data + Data("\n".utf8)) }
            }
            send(Progress(status: "Pulling from \(repository)", id: label))
            var firstError: Error?
            for (index, platform) in platforms.enumerated() {
                do {
                    if index > 0 {
                        send(Progress(status: "No \(platforms[0]) variant; pulling \(platform), which runs under Rosetta",
                                      id: label))
                    }
                    var lastPhase = ""
                    for try await line in backend.pullImage(reference.canonical, platform: platform) {
                        guard let progress = PullProgress.parse(line) else { continue }
                        let percent = progress.overall.map { Int(($0 * 100).rounded()) }
                        if progress.phase == lastPhase && percent == nil { continue }
                        lastPhase = progress.phase
                        send(Progress(status: progress.phase,
                                      progressDetail: percent.map { .init(current: $0, total: 100) },
                                      id: label))
                    }
                    send(Progress(status: "Status: Downloaded newer image for \(reference.familiar)"))
                    firstError = nil
                    break
                } catch is CancellationError {
                    firstError = nil
                    break
                } catch {
                    firstError = firstError ?? error
                }
            }
            if let firstError {
                let message = firstError.localizedDescription
                send(Progress(errorDetail: .init(message: message), error: message))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: .stream(stream))
    }
}
