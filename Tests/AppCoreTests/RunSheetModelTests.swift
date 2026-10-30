import XCTest
import ContainerKit
@testable import AppCore

@MainActor
final class RunSheetModelTests: XCTestCase {

    func testFormRunsTheConfiguredCommand() async {
        let mock = MockCLI()
        let model = RunSheetModel(image: "nginx:alpine")
        model.config.name = "site"
        model.config.ports = [.init(host: "8080", container: "80")]
        XCTAssertTrue(model.canRun)

        let started = await model.run(engine: CLIEngine(cli: mock, stream: CLIStream()))
        XCTAssertTrue(started)
        XCTAssertEqual(mock.runCalls.last, ["run", "--detach", "--name", "site", "--publish", "8080:80", "nginx:alpine"])
        XCTAssertEqual(model.containerName, "site")
    }

    func testErrorsBlockRunning() {
        let model = RunSheetModel()
        XCTAssertFalse(model.canRun, "no image")
        model.config.image = "alpine"
        model.config.name = "web"
        model.existingNames = ["web"]
        XCTAssertFalse(model.canRun, "name taken")
        model.config.name = ""
        XCTAssertTrue(model.canRun)
    }

    func testWarningsDoNotBlockAndSuggestionsApply() throws {
        let model = RunSheetModel(image: "alpine")
        model.config.ports = [.init(host: "5000", container: "5000")]
        XCTAssertTrue(model.canRun, "the AirPlay port is a warning, not an error")
        let suggestion = try XCTUnwrap(model.issues.first?.suggestion)
        model.apply(suggestion)
        XCTAssertEqual(model.config.ports.first?.host, "5050")
        XCTAssertTrue(model.issues.isEmpty)
    }

    func testPastedDockerRunIsDetached() async {
        let mock = MockCLI()
        let model = RunSheetModel()
        model.mode = .paste
        model.pasted = "docker run --name web -p 8080:80 nginx:alpine"
        XCTAssertTrue(model.canRun)
        XCTAssertTrue(model.commandLine.hasPrefix("container run --detach"), model.commandLine)
        XCTAssertEqual(model.containerName, "web")

        _ = await model.run(engine: CLIEngine(cli: mock, stream: CLIStream()))
        let call = mock.runCalls.last ?? []
        XCTAssertEqual(Array(call.prefix(2)), ["run", "--detach"])
        XCTAssertEqual(call.filter { $0 == "--detach" }.count, 1)
        XCTAssertEqual(call.last, "nginx:alpine")
    }

    func testRunFailureIsShown() async {
        let mock = MockCLI()
        mock.runError = EngineError.commandFailed(exitCode: 1, message: "image not found")
        let model = RunSheetModel(image: "nope:latest")
        let started = await model.run(engine: CLIEngine(cli: mock, stream: CLIStream()))
        XCTAssertFalse(started)
        XCTAssertEqual(model.runError, "image not found")
    }
}
