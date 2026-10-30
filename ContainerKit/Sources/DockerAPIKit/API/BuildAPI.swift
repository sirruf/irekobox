import Foundation
import ContainerKit

/// `POST /build`, the classic builder protocol: the body is the build context
/// as a (possibly compressed) tar, the output one JSON object per line.
/// The build itself runs on `container build` (BuildKit in its builder VM).
///
/// The docker CLI uses this protocol with `DOCKER_BUILDKIT=0`; by default it
/// goes through buildx, which wants BuildKit on `/grpc` (not served).
public enum BuildAPI {
    public static func register(on router: inout DockerRouter, backend: DockerBackend) {
        router.add("POST", "/build") { request in
            await respond { try await build(request, backend) }
        }
        router.add("POST", "/build/prune") { _ in
            .json(PruneReport(CachesDeleted: nil, SpaceReclaimed: 0))
        }
    }

    struct PruneReport: Encodable {
        let CachesDeleted: [String]?
        let SpaceReclaimed: Int
    }

    struct Message: Encodable {
        struct Aux: Encodable { let ID: String }
        struct ErrorDetail: Encodable { let message: String }
        var stream: String?
        var aux: Aux?
        var errorDetail: ErrorDetail?
        var error: String?
    }

    /// The build request, validated before anything runs.
    struct Plan: Equatable {
        var tags: [String]
        var dockerfile: String
        var buildArguments: [String]
        var labels: [String]
        var target: String?
        var platforms: [String]
        var noCache: Bool
        var pull: Bool
        var quiet: Bool
    }

    static func plan(_ request: DockerRequest) throws -> Plan {
        if let remote = request.query["remote"], !remote.isEmpty {
            throw DockerAPIError.badParameter("remote build contexts are not supported; send the context in the body")
        }
        var tags: [String] = []
        for text in request.http.queryValues("t") where !text.isEmpty {
            guard let reference = ImageReference(text) else { throw DockerAPIError.badParameter("invalid reference format: \(text)") }
            tags.append(reference.canonical)
        }
        let dockerfile = request.query["dockerfile"].flatMap { $0.isEmpty ? nil : $0 } ?? "Dockerfile"
        if dockerfile.hasPrefix("/") || dockerfile.split(separator: "/").contains("..") {
            throw DockerAPIError.badParameter("the Dockerfile must be inside the build context: \(dockerfile)")
        }
        func object(_ name: String) throws -> [String: String?] {
            guard let text = request.query[name], !text.isEmpty else { return [:] }
            guard let value = try? JSONDecoder().decode([String: String?].self, from: Data(text.utf8)) else {
                throw DockerAPIError.badParameter("\(name) must be a JSON object of strings")
            }
            return value
        }
        // A build arg without a value takes it from the client's environment,
        // which the CLI has already resolved; a null one is left unset.
        let buildArguments = try object("buildargs").sorted { $0.key < $1.key }
            .compactMap { key, value in value.map { "\(key)=\($0)" } }
        let labels = try object("labels").sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value ?? "")" }
        let platforms = (request.query["platform"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Plan(tags: tags, dockerfile: dockerfile, buildArguments: buildArguments, labels: labels,
                    target: request.query["target"].flatMap { $0.isEmpty ? nil : $0 },
                    platforms: platforms, noCache: request.bool("nocache"), pull: request.bool("pull"),
                    quiet: request.bool("q"))
    }

    static func build(_ request: DockerRequest, _ backend: DockerBackend) async throws -> HTTPResponse {
        let plan = try plan(request)
        let folder = try ArchiveAPI.scratch()
        let context = folder.appending(path: "context")
        do {
            try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
            try await Tar.extract(request.http, into: context)
            guard FileManager.default.fileExists(atPath: context.appending(path: plan.dockerfile).path) else {
                throw DockerAPIError(400, "Cannot locate specified Dockerfile: \(plan.dockerfile)")
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        // container build names every image; an untagged docker build gets
        // the CLI's own kind of name (a UUID) so its ID can be looked up.
        let primary = plan.tags.first ?? "docker.io/library/\(UUID().uuidString.lowercased()):latest"
        var options = BuildOptions(contextPath: context.path,
                                   dockerfilePath: context.appending(path: plan.dockerfile).path,
                                   tag: primary, noCache: plan.noCache)
        options.buildArguments = plan.buildArguments
        options.labels = plan.labels
        options.target = plan.target
        options.pull = plan.pull
        options.platforms = plan.platforms

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let task = Task {
            func send(_ message: Message) {
                if let data = try? JSONEncoder().encode(message) { continuation.yield(data + Data("\n".utf8)) }
            }
            func fail(_ text: String) {
                send(Message(errorDetail: .init(message: text), error: text))
            }
            defer {
                try? FileManager.default.removeItem(at: folder)
                continuation.finish()
            }
            var tail: [String] = []
            do {
                for try await line in backend.buildImage(options) {
                    tail = Array((tail + [line]).suffix(20))
                    if !plan.quiet { send(Message(stream: line + "\n")) }
                }
            } catch {
                // The CLI's error, else the last lines (BuildKit prints the
                // failing step there).
                let detail = error.localizedDescription
                fail(detail.isEmpty ? tail.joined(separator: "\n") : detail)
                return
            }
            for tag in plan.tags.dropFirst() {
                do {
                    try await backend.tagImage(primary, as: tag)
                } catch {
                    fail("tagging \(tag) failed: \(error.localizedDescription)")
                    return
                }
            }
            guard let image = try? await ImageDirectory(backend: backend).resolve(primary).0 else {
                fail("the build finished but its image \(primary) wasn't found")
                return
            }
            send(Message(aux: .init(ID: image.id)))
            if plan.quiet {
                send(Message(stream: image.id + "\n"))
            } else {
                send(Message(stream: "Successfully built \(image.id.dropFirst(7).prefix(12))\n"))
                for tag in plan.tags {
                    send(Message(stream: "Successfully tagged \(ImageReference(tag)?.familiar ?? tag)\n"))
                }
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: .stream(stream))
    }
}
