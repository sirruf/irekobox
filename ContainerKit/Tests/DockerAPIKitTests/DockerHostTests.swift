import XCTest
import ContainerKit
@testable import DockerAPIKit

private struct EmptyBackend: DockerBackend {
    func systemStatus() async throws -> SystemStatus? { nil }
    func systemProperties() async throws -> String { "" }
    func listContainers(all: Bool) async throws -> [Container] { [] }
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

final class DockerHostTests: XCTestCase {

    func testSocketFollowsTheSetting() async throws {
        let path = "/tmp/ib-host-\(UUID().uuidString.prefix(8)).sock"
        let host = DockerHost(backend: EmptyBackend(), appVersion: "test", socketPath: path, exitsFile: nil)

        let initial = await host.status()
        XCTAssertFalse(initial.enabled || initial.listening)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))

        await host.setEnabled(true)
        let on = await host.status()
        XCTAssertTrue(on.listening)
        XCTAssertNil(on.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        // A second host on the same path can't take it and says why.
        let other = DockerHost(backend: EmptyBackend(), appVersion: "test", socketPath: path, exitsFile: nil)
        await other.setEnabled(true)
        let clash = await other.status()
        XCTAssertFalse(clash.listening)
        XCTAssertTrue(clash.error?.contains("Another process") == true)

        await host.setEnabled(false)
        try await Task.sleep(for: .milliseconds(100))
        let off = await host.status()
        XCTAssertFalse(off.listening)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the socket file goes away")
    }
}
