import XCTest
import ContainerKit
@testable import DockerAPIKit

private final class ImageEngine: DockerBackend, @unchecked Sendable {
    var images: [ContainerImage] = []
    var containers: [Container] = []
    var details: ImageDetails?
    private(set) var calls: [String] = []
    private let lock = NSLock()
    private func record(_ call: String) { lock.withLock { calls.append(call) } }

    func listImages() async throws -> [ContainerImage] { images }
    func listContainers(all: Bool) async throws -> [Container] { containers }
    func inspectImage(_ reference: String) async throws -> ImageDetails {
        guard let details else { throw EngineError.notFound(reference) }
        return details
    }
    func tagImage(_ source: String, as target: String) async throws { record("tag \(source) \(target)") }
    func deleteImage(_ reference: String, force: Bool) async throws { record("rmi \(reference) force=\(force)") }

    func systemStatus() async throws -> SystemStatus? { nil }
    func systemProperties() async throws -> String { "" }
    func startContainer(_ id: String) async throws {}
    func stopContainer(_ id: String, timeout: Int32?, signal: String?) async throws {}
    func killContainer(_ id: String, signal: String?) async throws {}
    func deleteContainer(_ id: String, force: Bool) async throws {}
    func waitContainer(_ id: String) async throws -> ContainerExit { ContainerExit(code: 0, exitedAt: nil) }
    func createContainer(_ arguments: [String]) async throws {}
    func createVolume(_ name: String) async throws {}
    func deleteVolume(_ name: String) async throws {}
    /// Platforms a pull fails for, as an image without that variant does.
    var missingPlatforms: Set<String> = []
    func pullImage(_ reference: String, platform: String?) -> AsyncThrowingStream<String, Error> {
        record("pull \(reference) \(platform ?? "-")")
        let missing = platform.map { missingPlatforms.contains($0) } ?? false
        return AsyncThrowingStream { $0.finish(throwing: missing ? EngineError.notFound(reference) : nil) }
    }
    func containerLogs(_ id: String, follow: Bool) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func containerStats(_ id: String) async throws -> ContainerStats { throw EngineError.notFound(id) }
    func bootstrapContainer(_ id: String, stdio: ProcessStdio) async throws {}
    func createProcess(_ container: String, process: String, spec: ProcessSpec, stdio: ProcessStdio) async throws {}
    func startProcess(_ container: String, process: String) async throws {}
    func resizeProcess(_ container: String, process: String, width: Int, height: Int) async throws {}
    func waitProcess(_ container: String, process: String) async throws -> ContainerExit { ContainerExit(code: 0, exitedAt: nil) }
    func execute(_ id: String, command: [String]) async throws -> Data { Data() }
    func copy(from source: String, to destination: String) async throws {}
    func exportContainer(_ id: String, to path: String) async throws {}
    func startServices() async throws {}
    func pruneImages(all: Bool) async throws {}
    func saveImages(_ references: [String], platform: String?, to path: String) async throws {}
    func loadImages(from path: String) async throws -> String { "" }
    func pushImage(_ reference: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    var buildLines: [String] = []
    var buildError: Error?
    private(set) var builds: [BuildOptions] = []
    func buildImage(_ options: BuildOptions) -> AsyncThrowingStream<String, Error> {
        lock.withLock { builds.append(options) }
        // The context must be unpacked while the build runs.
        record("dockerfile exists=\(FileManager.default.fileExists(atPath: options.dockerfilePath ?? ""))")
        let lines = buildLines, error = buildError
        return AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish(throwing: error)
        }
    }
}

final class ImagesAPITests: XCTestCase {

    private func image(_ reference: String, digest: String, created: String = "2026-10-21T22:37:22Z") throws -> ContainerImage {
        let json = #"""
        {"id":"\#(digest.dropFirst(7))","configuration":{"name":"\#(reference)","creationDate":"\#(created)",
         "descriptor":{"digest":"\#(digest)","mediaType":"m","size":1}},
         "variants":[{"size":3000,"platform":{"architecture":"arm64","os":"linux"}},{"size":9000,"platform":{"architecture":"amd64","os":"linux"}}]}
        """#
        return try JSONDecoder().decode(ContainerImage.self, from: Data(json.utf8))
    }

    private let alpine = "sha256:aaaa1111" + String(repeating: "0", count: 56)
    private let nginx = "sha256:bbbb2222" + String(repeating: "0", count: 56)

    private func setUp(search: @escaping ImagesAPI.Search = { _, _ in [] }) throws -> (DockerRouter, ImageEngine) {
        let engine = ImageEngine()
        engine.images = [try image("docker.io/library/alpine:latest", digest: alpine),
                         try image("docker.io/library/alpine:3.24", digest: alpine),
                         try image("docker.io/library/nginx:alpine", digest: nginx, created: "2026-10-22T00:00:00Z"),
                         try image("ghcr.io/apple/containerization/vminit:0.9.0", digest: "sha256:cc")]
        var router = DockerRouter()
        ImagesAPI.register(on: &router, backend: engine, search: search)
        BuildAPI.register(on: &router, backend: engine)
        return (router, engine)
    }

    private func json(_ response: HTTPResponse) throws -> Any {
        guard case .data(let data) = response.body else { return [] }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func pullOutput(_ router: DockerRouter, _ target: String) async throws -> String {
        let response = await router.handle(HTTPRequest(method: "POST", target: target))
        guard case .stream(let stream) = response.body else { return "" }
        var text = ""
        for try await chunk in stream { text += String(decoding: chunk, as: UTF8.self) }
        return text
    }

    func testPullFallsBackToAmd64WhenThereIsNoArm64Variant() async throws {
        let (router, engine) = try setUp()
        engine.missingPlatforms = ["linux/arm64"]
        let output = try await pullOutput(router, "/images/create?fromImage=redislabs/redismod&tag=latest")
        XCTAssertEqual(engine.calls.filter { $0.hasPrefix("pull") },
                       ["pull docker.io/redislabs/redismod:latest linux/arm64",
                        "pull docker.io/redislabs/redismod:latest linux/amd64"])
        XCTAssertTrue(output.contains("Downloaded newer image"))
        XCTAssertFalse(output.contains("errorDetail"))
    }

    func testPullWithAnExplicitPlatformDoesNotFallBack() async throws {
        let (router, engine) = try setUp()
        engine.missingPlatforms = ["linux/arm64"]
        let output = try await pullOutput(router, "/images/create?fromImage=alpine&tag=3&platform=linux/arm64")
        XCTAssertEqual(engine.calls.filter { $0.hasPrefix("pull") }.count, 1)
        XCTAssertTrue(output.contains("errorDetail"))
    }

    func testListGroupsTagsAndHidesSystemImages() async throws {
        let (router, _) = try setUp()
        let listResponse = await router.handle(HTTPRequest(method: "GET", target: "/images/json"))
        let list = try XCTUnwrap(try json(listResponse) as? [[String: Any]])
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.first?["RepoTags"] as? [String], ["nginx:alpine"], "newest first")
        let alpineRow = try XCTUnwrap(list.first { ($0["Id"] as? String) == alpine })
        XCTAssertEqual(alpineRow["RepoTags"] as? [String], ["alpine:3.24", "alpine:latest"])
        XCTAssertEqual(alpineRow["RepoDigests"] as? [String], ["alpine@\(alpine)"])
        XCTAssertEqual(alpineRow["Size"] as? Int, 3000, "the native variant")

        let filteredResponse = await router.handle(HTTPRequest(method: "GET",
            target: "/images/json?filters=%7B%22reference%22%3A%5B%22ngi*%22%5D%7D"))
        let filtered = try XCTUnwrap(try json(filteredResponse) as? [[String: Any]])
        XCTAssertEqual(filtered.compactMap { $0["Id"] as? String }, [nginx])
        let danglingResponse = await router.handle(HTTPRequest(method: "GET",
            target: "/images/json?filters=%7B%22dangling%22%3A%5B%22true%22%5D%7D"))
        let dangling = try XCTUnwrap(try json(danglingResponse) as? [[String: Any]])
        XCTAssertTrue(dangling.isEmpty)
    }

    func testResolveByTagIdAndPrefix() async throws {
        let (_, engine) = try setUp()
        let directory = ImageDirectory(backend: engine)
        for name in ["alpine", "alpine:3.24", "docker.io/library/alpine:latest", alpine, "aaaa1111", "sha256:aaaa"] {
            let (image, _) = try await directory.resolve(name)
            XCTAssertEqual(image.id, alpine, name)
        }
        do {
            _ = try await directory.resolve("busybox")
            XCTFail("missing")
        } catch let error as DockerAPIError {
            XCTAssertEqual(error, DockerAPIError(404, "No such image: busybox"))
        }
    }

    func testRemoveUntagsOneTagOrRefusesLikeDocker() async throws {
        let (router, engine) = try setUp()
        let untagResponse = await router.handle(HTTPRequest(method: "DELETE", target: "/images/alpine:3.24"))
        let untag = try XCTUnwrap(try json(untagResponse) as? [[String: String]])
        XCTAssertEqual(untag, [["Untagged": "alpine:3.24"]], "the image keeps its other tag")

        let byID = await router.handle(HTTPRequest(method: "DELETE", target: "/images/aaaa1111"))
        XCTAssertEqual(byID.status, 409, "several tags need force")

        let forcedResponse = await router.handle(HTTPRequest(method: "DELETE", target: "/images/aaaa1111?force=1"))
        let forced = try XCTUnwrap(try json(forcedResponse) as? [[String: String]])
        XCTAssertEqual(forced.last, ["Deleted": alpine])
        XCTAssertEqual(engine.calls, ["rmi docker.io/library/alpine:3.24 force=false",
                                      "rmi docker.io/library/alpine:3.24 force=true",
                                      "rmi docker.io/library/alpine:latest force=true"])
    }

    func testRemoveRefusesAnImageInUse() async throws {
        let (router, engine) = try setUp()
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/container-list-1.6.1", withExtension: "json"))
        engine.containers = try JSONDecoder().decode([Container].self, from: Data(contentsOf: fixture))
            .filter { $0.configuration.image.reference == "docker.io/library/redis:7-alpine" }
        engine.images.append(try image("docker.io/library/redis:7-alpine", digest: engine.containers[0].configuration.image.descriptor.digest))
        let response = await router.handle(HTTPRequest(method: "DELETE", target: "/images/redis:7-alpine"))
        XCTAssertEqual(response.status, 409)
        XCTAssertTrue(engine.calls.isEmpty)
    }

    func testTagAndHistory() async throws {
        let (router, engine) = try setUp()
        let tagged = await router.handle(HTTPRequest(method: "POST", target: "/images/alpine/tag?repo=me/tool&tag=v1"))
        XCTAssertEqual(tagged.status, 201)
        XCTAssertEqual(engine.calls, ["tag docker.io/library/alpine:latest docker.io/me/tool:v1"])

        engine.details = try JSONDecoder().decode(ImageDetails.self, from: Data(#"""
        {"id":"x","configuration":{"name":"docker.io/library/alpine:latest","descriptor":{"digest":"\#(alpine)","mediaType":"m","size":1}},
         "variants":[{"platform":{"architecture":"arm64","os":"linux"},"size":3000,
           "config":{"created":"2026-10-21T22:37:22Z","config":{"Cmd":["/bin/sh"]},"rootfs":{"type":"layers","diff_ids":["sha256:l1"]},
                     "history":[{"created":"2026-10-21T22:37:21Z","created_by":"ADD rootfs"},{"created":"2026-10-21T22:37:22Z","created_by":"CMD [\"/bin/sh\"]","empty_layer":true}]}}]}
        """#.utf8))
        let historyResponse = await router.handle(HTTPRequest(method: "GET", target: "/images/alpine/history"))
        let history = try XCTUnwrap(try json(historyResponse) as? [[String: Any]])
        XCTAssertEqual(history.compactMap { $0["CreatedBy"] as? String }, [#"CMD ["/bin/sh"]"#, "ADD rootfs"], "newest first")
        XCTAssertEqual(history.first?["Id"] as? String, alpine)
        XCTAssertEqual(history.last?["Id"] as? String, "<missing>")

        let inspectResponse = await router.handle(HTTPRequest(method: "GET", target: "/images/alpine/json"))
        let inspect = try XCTUnwrap(try json(inspectResponse) as? [String: Any])
        XCTAssertEqual((inspect["Config"] as? [String: Any])?["Cmd"] as? [String], ["/bin/sh"])
        XCTAssertEqual((inspect["RootFS"] as? [String: Any])?["Layers"] as? [String], ["sha256:l1"])
        XCTAssertEqual(inspect["Architecture"] as? String, "arm64")
    }

    func testSearchFilters() async throws {
        let (router, _) = try setUp { term, limit in
            XCTAssertEqual(term, "redis")
            return [SearchResult(name: "redis", description: "official", star_count: 13000, is_official: true, is_automated: false),
                    SearchResult(name: "someone/redis", description: "fork", star_count: 3, is_official: false, is_automated: false)]
        }
        let officialResponse = await router.handle(HTTPRequest(method: "GET",
            target: "/images/search?term=redis&filters=%7B%22is-official%22%3A%5B%22true%22%5D%7D"))
        let official = try XCTUnwrap(try json(officialResponse) as? [[String: Any]])
        XCTAssertEqual(official.compactMap { $0["name"] as? String }, ["redis"])
        let starsResponse = await router.handle(HTTPRequest(method: "GET",
            target: "/images/search?term=redis&filters=%7B%22stars%22%3A%5B%22100%22%5D%7D"))
        let stars = try XCTUnwrap(try json(starsResponse) as? [[String: Any]])
        XCTAssertEqual(stars.count, 1)
    }

    // MARK: - Build

    private func context(_ files: [String: String]) throws -> Data {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ctx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, text) in files {
            let url = folder.appending(path: name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-c", "-f", "-", "-C", folder.path] + files.keys.sorted()
        let out = Pipe()
        tar.standardOutput = out
        try tar.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        tar.waitUntilExit()
        return data
    }

    private func messages(_ response: HTTPResponse) async throws -> [[String: Any]] {
        guard case .stream(let stream) = response.body else { return [] }
        var data = Data()
        for try await chunk in stream { data += chunk }
        return try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func testBuildPlanReadsDockersQuery() throws {
        let request = DockerRequest(http: HTTPRequest(method: "POST",
            target: "/build?t=me/app:1&t=me/app:latest&dockerfile=docker/Dockerfile.dev&target=prod&nocache=1&pull=1"
                + "&buildargs=%7B%22A%22%3A%221%22%2C%22B%22%3Anull%7D&labels=%7B%22team%22%3A%22core%22%7D&platform=linux/arm64,linux/amd64"),
            parameters: [:], apiVersion: DockerAPIVersion.current)
        let plan = try BuildAPI.plan(request)
        XCTAssertEqual(plan.tags, ["docker.io/me/app:1", "docker.io/me/app:latest"])
        XCTAssertEqual(plan.dockerfile, "docker/Dockerfile.dev")
        XCTAssertEqual(plan.buildArguments, ["A=1"], "a null build arg stays unset")
        XCTAssertEqual(plan.labels, ["team=core"])
        XCTAssertEqual(plan.target, "prod")
        XCTAssertEqual(plan.platforms, ["linux/arm64", "linux/amd64"])
        XCTAssertTrue(plan.noCache && plan.pull)

        for bad in ["/build?dockerfile=../x", "/build?dockerfile=/etc/passwd", "/build?remote=https://x/y.git"] {
            XCTAssertThrowsError(try BuildAPI.plan(DockerRequest(http: HTTPRequest(method: "POST", target: bad), parameters: [:], apiVersion: DockerAPIVersion.current)), bad)
        }
    }

    func testBuildStreamsProgressTagsAndReportsTheID() async throws {
        let (router, engine) = try setUp()
        engine.buildLines = ["#1 [internal] load build definition", "#5 DONE 0.1s"]
        // The built image is the one the build tag names.
        engine.images.append(try image("docker.io/me/app:1", digest: alpine))
        let body = try context(["Dockerfile": "FROM alpine\n"])
        let response = await router.handle(HTTPRequest(method: "POST", target: "/build?t=me/app:1&t=me/app:stable", body: body))
        XCTAssertEqual(response.status, 200)
        let lines = try await messages(response)
        XCTAssertEqual(lines.first?["stream"] as? String, "#1 [internal] load build definition\n")
        XCTAssertTrue(lines.contains { ($0["aux"] as? [String: String])?["ID"] == alpine })
        XCTAssertEqual(lines.last?["stream"] as? String, "Successfully tagged me/app:stable\n")
        XCTAssertEqual(engine.builds.first?.tag, "docker.io/me/app:1")
        XCTAssertEqual(engine.calls, ["dockerfile exists=true", "tag docker.io/me/app:1 docker.io/me/app:stable"])
    }

    func testBuildFailuresAreReportedInTheStream() async throws {
        let (router, engine) = try setUp()
        engine.buildError = EngineError.commandFailed(exitCode: 1,
                                                      message: "failed to solve: exit code: 3")
        let body = try context(["Dockerfile": "FROM alpine\nRUN exit 3\n"])
        let lines = try await messages(await router.handle(HTTPRequest(method: "POST", target: "/build?t=x", body: body)))
        XCTAssertNotNil(lines.last?["error"] as? String)

        let missing = await router.handle(HTTPRequest(method: "POST", target: "/build?dockerfile=Other",
                                                      body: try context(["Dockerfile": "FROM alpine\n"])))
        XCTAssertEqual(missing.status, 400)
    }
}
