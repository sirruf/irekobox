import XCTest
import SwiftTerm
import ContainerKit
@testable import AppCore

@MainActor
final class ConsoleTests: XCTestCase {

    func testShellArguments() {
        // A UTF-8 locale, or the shell garbles Cyrillic input.
        let env = ["--env", "LANG=C.UTF-8", "--env", "TERM=xterm-256color"]
        XCTAssertEqual(ConsoleShell.bash.arguments(containerID: "web"),
                       ["exec", "--interactive", "--tty"] + env + ["web", "bash"])
        let auto = ConsoleShell.auto.arguments(containerID: "web")
        XCTAssertEqual(Array(auto.prefix(10)), ["exec", "--interactive", "--tty"] + env + ["web", "sh", "-c"])
        XCTAssertEqual(MachineRepository.shellArguments("dev"),
                       ["machine", "run", "--interactive", "--tty"] + env + ["-n", "dev"])
        XCTAssertTrue(auto.last!.contains("command -v bash"))
    }

    /// Closing the terminal view must end its process (no lingering `exec`).
    func testDismantleEndsTheSession() async throws {
        var exited = false
        let view = ContainerTerminalView(binaryPath: "/bin/sleep", arguments: ["30"], onExit: { _ in exited = true })
        let coordinator = view.makeCoordinator()
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        terminal.processDelegate = coordinator
        terminal.startProcess(executable: "/bin/sleep", args: ["30"])
        let pid = terminal.process.shellPid
        XCTAssertGreaterThan(pid, 0)
        XCTAssertEqual(kill(pid, 0), 0, "the session is running")

        ContainerTerminalView.dismantleNSView(terminal, coordinator: coordinator)
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotEqual(kill(pid, 0), 0, "the process is gone (and reaped, not a zombie) after dismantle")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(exited, "ending the session ourselves is not reported as an exit")
    }

    func testWaitStatusDecoding() {
        XCTAssertEqual(ContainerTerminalView.exitCode(fromWaitStatus: 0), 0)
        XCTAssertEqual(ContainerTerminalView.exitCode(fromWaitStatus: 3 << 8), 3)
        XCTAssertEqual(ContainerTerminalView.exitCode(fromWaitStatus: SIGKILL), 137)
    }

    func testShellExitIsReported() async throws {
        let reported = expectation(description: "exit reported")
        var code: Int32??
        let view = ContainerTerminalView(binaryPath: "/bin/sh", arguments: ["-c", "exit 3"]) { exit in
            code = .some(exit)
            reported.fulfill()
        }
        let coordinator = view.makeCoordinator()
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        terminal.processDelegate = coordinator
        terminal.startProcess(executable: "/bin/sh", args: ["-c", "exit 3"])
        await fulfillment(of: [reported], timeout: 5)
        XCTAssertEqual(code, .some(3))
    }
}
