import XCTest
import ContainerKit
import StackKit
@testable import AppCore

/// Runs a two-service project, edits one service and applies:
/// IREKOBOX_LIVE_COMPOSE=1 IREKOBOX_SCRATCH=<dir> swift test --filter ComposeApplyLive
/// Uses only containers and networks named ibedit-*; removes them at the end.
@MainActor
final class ComposeApplyLiveTests: XCTestCase {
    func testApplyRecreatesOnlyWhatChanged() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["IREKOBOX_LIVE_COMPOSE"] == "1", "live only")
        let folder = URL(fileURLWithPath: try XCTUnwrap(env["IREKOBOX_SCRATCH"])).appending(path: "ibedit")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "compose.yaml")
        let original = """
        services:
          web:
            image: nginx:alpine
            ports: ["18090:80"]
          worker:
            image: alpine
            command: sleep infinity
        """
        try original.write(to: file, atomically: true, encoding: .utf8)

        let cli = ContainerCLI()
        let engine = CLIEngine(cli: cli, stream: CLIStream())
        let model = ComposeViewModel(engine: engine, runner: ComposeRunner(runner: cli))
        let entry = StackEntry(name: "ibedit", composePath: file.path)
        func project() async throws -> ComposeProject {
            let containers = try await engine.listContainers(all: true)
            return try XCTUnwrap(ComposeProject.all(entries: [entry], containers: containers).first)
        }
        defer {
            Task { @MainActor in await model.removeContainers(try! await project()) }
        }

        await model.start(try await project())
        var current = try await project()
        XCTAssertNil(model.error)
        XCTAssertEqual(current.running, 2, model.error ?? "")
        let webCreated = current.containers.first { $0.id == "ibedit-web" }?.configuration.creationDate

        // Nothing edited: nothing to do.
        guard case .success(let same) = model.preview(current, text: original) else { return XCTFail("preview") }
        XCTAssertEqual(Set(same.changes), [.keep(service: "web"), .keep(service: "worker")])

        // Change the worker only.
        let edited = original.replacingOccurrences(of: "command: sleep infinity", with: "command: sleep 99999")
        guard case .success(let preview) = model.preview(current, text: edited) else { return XCTFail("preview") }
        XCTAssertEqual(Set(preview.changes), [.keep(service: "web"), .recreate(service: "worker", container: "ibedit-worker")])
        await model.apply(current, text: edited, to: file.path, dockerSocket: nil)
        XCTAssertNil(model.error)
        current = try await project()
        XCTAssertEqual(current.running, 2)
        XCTAssertEqual(current.containers.first { $0.id == "ibedit-web" }?.configuration.creationDate, webCreated,
                       "web was left alone")
        XCTAssertEqual(current.containers.first { $0.id == "ibedit-worker" }?.configuration.initProcess.arguments, ["99999"])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), edited)

        await model.removeContainers(current)
        current = try await project()
        XCTAssertTrue(current.containers.isEmpty)
        for network in ["ibedit-default"] { _ = try? await cli.run(["network", "delete", network]) }
    }
}
