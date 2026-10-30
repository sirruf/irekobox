import XCTest
import ContainerKit
@testable import DockerAPIKit

private final class ExecEngine: DockerBackend, @unchecked Sendable {
    let containers: [Container]
    private(set) var specs: [String: ProcessSpec] = [:]
    private let lock = NSLock()
    init(containers: [Container]) { self.containers = containers }

    func systemStatus() async throws -> SystemStatus? { nil }
    func systemProperties() async throws -> String { "" }
    func listContainers(all: Bool) async throws -> [Container] { containers }
    func listImages() async throws -> [ContainerImage] { [] }
    func startContainer(_ id: String) async throws {}
    func stopContainer(_ id: String, timeout: Int32?, signal: String?) async throws {}
    func killContainer(_ id: String, signal: String?) async throws {}
    func deleteContainer(_ id: String, force: Bool) async throws {}
    func waitContainer(_ id: String) async throws -> ContainerExit { ContainerExit(code: 0, exitedAt: nil) }
    func createContainer(_ arguments: [String]) async throws {}
    func createVolume(_ name: String) async throws {}
    func deleteVolume(_ name: String) async throws {}
    func pullImage(_ reference: String, platform: String?) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func containerLogs(_ id: String, follow: Bool) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func containerStats(_ id: String) async throws -> ContainerStats { throw EngineError.notFound(id) }
    func bootstrapContainer(_ id: String, stdio: ProcessStdio) async throws {}
    func createProcess(_ container: String, process: String, spec: ProcessSpec, stdio: ProcessStdio) async throws {
        lock.withLock { specs[process] = spec }
    }
    func startProcess(_ container: String, process: String) async throws {}
    func resizeProcess(_ container: String, process: String, width: Int, height: Int) async throws {}
    func waitProcess(_ container: String, process: String) async throws -> ContainerExit { ContainerExit(code: 7, exitedAt: nil) }
    func execute(_ id: String, command: [String]) async throws -> Data { Data() }
    func copy(from source: String, to destination: String) async throws {}
    func exportContainer(_ id: String, to path: String) async throws {}
    func startServices() async throws {}
    func deleteImage(_ reference: String, force: Bool) async throws {}
    func pruneImages(all: Bool) async throws {}
    func inspectImage(_ reference: String) async throws -> ImageDetails { throw EngineError.notFound(reference) }
    func tagImage(_ source: String, as target: String) async throws {}
    func saveImages(_ references: [String], platform: String?, to path: String) async throws {}
    func loadImages(from path: String) async throws -> String { "" }
    func pushImage(_ reference: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func buildImage(_ options: BuildOptions) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
}

final class ExecAPITests: XCTestCase {

    private func setUp() throws -> (DockerRouter, ExecEngine) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/container-list-1.6.1", withExtension: "json"))
        let engine = ExecEngine(containers: try JSONDecoder().decode([Container].self, from: Data(contentsOf: url)))
        var router = DockerRouter()
        ExecAPI.register(on: &router, backend: engine, attaches: AttachRegistry(), execs: ExecRegistry(), exits: nil)
        return (router, engine)
    }

    private func json(_ response: HTTPResponse) throws -> [String: Any] {
        guard case .data(let data) = response.body else { return [:] }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testExecInheritsTheContainerAndRunsOnce() async throws {
        let (router, engine) = try setUp()
        let create = await router.handle(HTTPRequest(method: "POST", target: "/containers/ib-fx-redis/exec", body: Data(#"""
        {"AttachStdout":true,"Cmd":["redis-cli","ping"],"Env":["FOO=override","NEW=1"]}
        """#.utf8)))
        XCTAssertEqual(create.status, 201)
        let id = try XCTUnwrap(json(create)["Id"] as? String)
        XCTAssertEqual(id.count, 64)

        let start = await router.handle(HTTPRequest(method: "POST", target: "/exec/\(id)/start", body: Data(#"{"Detach":true}"#.utf8)))
        XCTAssertEqual(start.status, 200)
        let spec = try XCTUnwrap(engine.specs[id])
        XCTAssertEqual(spec.executable, "redis-cli")
        XCTAssertEqual(spec.arguments, ["ping"])
        XCTAssertEqual(spec.workingDirectory, "/data", "the container's WORKDIR")
        XCTAssertTrue(spec.environment.contains("FOO=override") && spec.environment.contains("NEW=1"))
        XCTAssertFalse(spec.environment.contains("FOO=bar"), "overridden, not duplicated")
        XCTAssertTrue(spec.environment.contains { $0.hasPrefix("PATH=") }, "inherits the container's PATH")

        let again = await router.handle(HTTPRequest(method: "POST", target: "/exec/\(id)/start", body: Data(#"{"Detach":true}"#.utf8)))
        XCTAssertEqual(again.status, 409)
        try await Task.sleep(for: .milliseconds(100))
        let inspect = try json(await router.handle(HTTPRequest(method: "GET", target: "/exec/\(id)/json")))
        XCTAssertEqual(inspect["ExitCode"] as? Int, 7)
        XCTAssertEqual(inspect["Running"] as? Bool, false)
    }

    func testExecRules() async throws {
        let (router, _) = try setUp()
        let stopped = await router.handle(HTTPRequest(method: "POST", target: "/containers/ib-fx-stopped/exec",
                                                      body: Data(#"{"Cmd":["sh"]}"#.utf8)))
        XCTAssertEqual(stopped.status, 409)
        let empty = await router.handle(HTTPRequest(method: "POST", target: "/containers/ib-fx-redis/exec", body: Data("{}".utf8)))
        XCTAssertEqual(empty.status, 400)
        let unknown = await router.handle(HTTPRequest(method: "GET", target: "/exec/nope/json"))
        XCTAssertEqual(unknown.status, 404)
    }
}
