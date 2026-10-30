import XCTest
@testable import ContainerKit

/// What containerWait does, against the live apiserver.
/// IREKOBOX_LIVE_TESTS=1 swift test --filter XPCWaitLiveTests
final class XPCWaitLiveTests: XCTestCase {
    func testWaitReturnsTheExitCode() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IREKOBOX_LIVE_TESTS"] == "1")
        let engine = XPCEngine(fallback: CLIEngine())
        let name = "ib-wait-\(UUID().uuidString.prefix(6).lowercased())"
        try await engine.runContainer(["--detach", "--name", name, "alpine:latest", "sh", "-c", "sleep 2; exit 7"])
        defer { Task { try? await engine.deleteContainer(name, force: true) } }

        let started = Date()
        let exit = try await engine.waitContainer(name)
        print("WAIT running→exit: code=\(exit.code) exitedAt=\(String(describing: exit.exitedAt)) after \(Date().timeIntervalSince(started))s")
        XCTAssertEqual(exit.code, 7)

        // And once it is already stopped?
        let again: String
        do {
            let second = try await engine.waitContainer(name)
            again = "code=\(second.code) exitedAt=\(String(describing: second.exitedAt))"
        } catch {
            again = "error: \(error)"
        }
        print("WAIT stopped: \(again)")
        let state = try await engine.inspectContainer(name).state
        print("STATE after exit: \(state.rawValue)")
        try await engine.deleteContainer(name, force: true)
    }

    func testWaitOnANeverStartedContainer() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IREKOBOX_LIVE_TESTS"] == "1")
        let engine = XPCEngine(fallback: CLIEngine())
        let name = "ib-created-\(UUID().uuidString.prefix(6).lowercased())"
        _ = try await ContainerCLI().data(["create", "--name", name, "alpine:latest", "true"])
        let outcome = await withTaskGroup(of: String.self) { group in
            group.addTask {
                do { let exit = try await engine.waitContainer(name); return "code=\(exit.code) exitedAt=\(String(describing: exit.exitedAt))" }
                catch { return "error: \(error)" }
            }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return "still waiting after 3 s" }
            let first = await group.next() ?? ""
            group.cancelAll()
            return first
        }
        let snapshot = try await engine.inspectContainer(name)
        print("CREATED wait: \(outcome); state=\(snapshot.state.rawValue) started=\(String(describing: snapshot.status.startedDate))")
        try await engine.deleteContainer(name, force: true)
    }

    func testWaitAfterAnUnwatchedExit() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IREKOBOX_LIVE_TESTS"] == "1")
        let engine = XPCEngine(fallback: CLIEngine())
        for name in ["ib-exit7"] {
            do { let exit = try await engine.waitContainer(name); print("UNWATCHED \(name): code=\(exit.code) at=\(String(describing: exit.exitedAt))") }
            catch { print("UNWATCHED \(name): \(error)") }
            let c = try await engine.inspectContainer(name)
            print("UNWATCHED \(name) state=\(c.state.rawValue) started=\(String(describing: c.status.startedDate))")
        }
    }
}
