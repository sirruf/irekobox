import XCTest
import ContainerKit
@testable import DockerAPIKit

private struct StubBackend: DockerBackend {
    var status: SystemStatus?
    var properties = """
    [kernel]
    binaryPath = "opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug"
    """
    var containers: [Container] = []
    var images: [ContainerImage] = []

    func systemStatus() async throws -> SystemStatus? { status }
    func systemProperties() async throws -> String { properties }
    func listContainers(all: Bool) async throws -> [Container] { containers }
    func listImages() async throws -> [ContainerImage] { images }
    func startContainer(_ id: String) async throws {}
    func stopContainer(_ id: String, timeout: Int32?, signal: String?) async throws {}
    func killContainer(_ id: String, signal: String?) async throws {}
    func deleteContainer(_ id: String, force: Bool) async throws {}
    func waitContainer(_ id: String) async throws -> ContainerExit { ContainerExit(code: 0, exitedAt: nil) }
    func createContainer(_ arguments: [String]) async throws {}
    func createVolume(_ name: String) async throws {}
    func deleteVolume(_ name: String) async throws {}
    func pullImage(_ reference: String, platform: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func containerLogs(_ id: String, follow: Bool) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func containerStats(_ id: String) async throws -> ContainerStats {
        ContainerStats(id: id, cpuUsageUsec: 0, memoryUsageBytes: 0, memoryLimitBytes: 0, networkRxBytes: 0,
                       networkTxBytes: 0, blockReadBytes: 0, blockWriteBytes: 0, numProcesses: 0)
    }
    func bootstrapContainer(_ id: String, stdio: ProcessStdio) async throws {}
    func createProcess(_ container: String, process: String, spec: ProcessSpec, stdio: ProcessStdio) async throws {}
    func startProcess(_ container: String, process: String) async throws {}
    func resizeProcess(_ container: String, process: String, width: Int, height: Int) async throws {}
    func waitProcess(_ container: String, process: String) async throws -> ContainerExit { ContainerExit(code: 0, exitedAt: nil) }
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

final class SystemAPITests: XCTestCase {

    private let host = DockerHostInfo(appVersion: "0.9.0", hostName: "mac", cpus: 10,
                                      memoryBytes: 32 << 30, macOSVersion: "26.1")

    private func runningStatus() throws -> SystemStatus {
        let json = #"""
        {"status":"running","server":{"appName":"container-apiserver","version":"1.6.1","commit":"aa8d76b44a83"},
         "host":{"architecture":"arm64","cpus":10},"paths":{"appRoot":"/Users/me/Library/Application Support/com.apple.container"}}
        """#
        return try JSONDecoder().decode(SystemStatus.self, from: Data(json.utf8))
    }

    private func router(_ backend: StubBackend) -> DockerRouter {
        var router = DockerRouter()
        SystemAPI.register(on: &router, backend: backend, host: host)
        return router
    }

    private func json(_ response: HTTPResponse) throws -> [String: Any] {
        guard case .data(let data) = response.body else { XCTFail("not data"); return [:] }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testPing() async {
        let response = await router(StubBackend()).handle(HTTPRequest(method: "HEAD", target: "/_ping"))
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(response.headers.contains { $0.name == "Builder-Version" })
    }

    func testVersionReportsTheAPIRangeAndComponents() async throws {
        let response = await router(StubBackend(status: try runningStatus())).handle(HTTPRequest(method: "GET", target: "/v1.44/version"))
        let body = try json(response)
        XCTAssertEqual(body["ApiVersion"] as? String, "1.56")
        XCTAssertEqual(body["MinAPIVersion"] as? String, "1.24")
        XCTAssertEqual(body["Os"] as? String, "linux")
        XCTAssertEqual(body["KernelVersion"] as? String, "6.18.35-197-debug")
        let components = try XCTUnwrap(body["Components"] as? [[String: Any]])
        XCTAssertEqual(components.map { $0["Name"] as? String }, ["Engine", "Irekobox", "container"])
        XCTAssertEqual(components.last?["Version"] as? String, "1.6.1")
    }

    func testInfo() async throws {
        let response = await router(StubBackend(status: try runningStatus())).handle(HTTPRequest(method: "GET", target: "/info"))
        XCTAssertEqual(response.status, 200)
        let body = try json(response)
        XCTAssertEqual(body["OSType"] as? String, "linux")
        XCTAssertEqual(body["Architecture"] as? String, "aarch64")
        XCTAssertEqual(body["NCPU"] as? Int, 10)
        XCTAssertEqual(body["MemTotal"] as? Int, 32 << 30)
        XCTAssertEqual(body["Containers"] as? Int, 0)
        XCTAssertEqual((body["Swarm"] as? [String: Any])?["LocalNodeState"] as? String, "inactive")
        XCTAssertTrue((body["OperatingSystem"] as? String)?.contains("1.6.1") == true)
    }

    func testInfoWhenTheEngineIsStopped() async throws {
        let stopped = try JSONDecoder().decode(SystemStatus.self, from: Data(#"{"status":"unregistered"}"#.utf8))
        let response = await router(StubBackend(status: stopped)).handle(HTTPRequest(method: "GET", target: "/info"))
        XCTAssertEqual(response.status, 500)
        XCTAssertTrue(try XCTUnwrap(json(response)["message"] as? String).contains("not running"))
    }

    func testSwarmAndPluginsAnswerLikeAStandaloneEngine() async throws {
        let api = router(StubBackend(status: try runningStatus()))
        for path in ["/swarm", "/v1.44/nodes", "/services/abc/update", "/secrets/create"] {
            let response = await api.handle(HTTPRequest(method: "GET", target: path))
            XCTAssertEqual(response.status, 503, path)
            XCTAssertTrue(try XCTUnwrap(json(response)["message"] as? String).hasPrefix("This node is not a swarm manager"))
        }
        let plugins = await api.handle(HTTPRequest(method: "GET", target: "/plugins"))
        XCTAssertEqual(plugins.status, 200)
        if case .data(let data) = plugins.body { XCTAssertEqual(String(decoding: data, as: UTF8.self), "[]\n") }
        let install = await api.handle(HTTPRequest(method: "POST", target: "/plugins/pull"))
        XCTAssertEqual(install.status, 501)
        let swarmish = await api.handle(HTTPRequest(method: "GET", target: "/swarming"))
        XCTAssertEqual(swarmish.status, 404, "a prefix matches whole segments only")
    }
}
