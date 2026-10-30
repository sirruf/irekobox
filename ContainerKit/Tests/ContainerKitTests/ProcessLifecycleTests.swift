import XCTest
@testable import ContainerKit

/// Process ownership tests: `/bin/sh` stands in for the `container` binary, so
/// `["-c", script]` runs an arbitrary script through the real execution paths.
final class ProcessLifecycleTests: XCTestCase {

    private let sh = "/bin/sh"

    private func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// The PID written by `echo $$ > file` from inside a script.
    private func pid(in file: URL, timeout: TimeInterval = 5) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw XCTSkip("script never wrote its pid")
    }

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ib-\(UUID().uuidString)")
    }

    // MARK: - One-shot commands

    func testSuccessReturnsStdout() async throws {
        let data = try await ContainerCLI(binaryPath: sh).data(["-c", "echo hello"])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello\n")
    }

    func testFailureCarriesStderr() async throws {
        do {
            try await ContainerCLI(binaryPath: sh).run(["-c", "echo boom >&2; exit 3"])
            XCTFail("expected failure")
        } catch let error as EngineError {
            XCTAssertEqual(error, .commandFailed(exitCode: 3, message: "boom"))
        }
    }

    /// `container system status --format json` exits 1 when the engine is
    /// stopped, but its stdout still says so.
    func testAcceptedExitCodeStillDecodes() async throws {
        struct Status: Decodable, Sendable { let status: String }
        let script = #"echo '{"status":"unregistered"}'; exit 1"#
        let status = try await ContainerCLI(binaryPath: sh).decode(Status.self, ["-c", script], alsoAccepting: [1])
        XCTAssertEqual(status.status, "unregistered")

        do {
            _ = try await ContainerCLI(binaryPath: sh).decode(Status.self, ["-c", script])
            XCTFail("exit 1 is a failure unless accepted")
        } catch let error as EngineError {
            if case .commandFailed(let code, _) = error { XCTAssertEqual(code, 1) } else { XCTFail("\(error)") }
        }
        do {
            _ = try await ContainerCLI(binaryPath: sh).decode(Status.self, ["-c", "exit 2"], alsoAccepting: [1])
            XCTFail("only the listed codes are accepted")
        } catch is EngineError {}
    }

    func testStderrClassifiedAsConflict() async throws {
        do {
            try await ContainerCLI(binaryPath: sh).run(["-c", "echo 'volume data already exists' >&2; exit 1"])
            XCTFail("expected failure")
        } catch let error as EngineError {
            XCTAssertEqual(error, .conflict("volume data already exists"))
        }
    }

    func testCancellationStopsProcess() async throws {
        let file = tempFile()
        let cli = ContainerCLI(binaryPath: sh)
        let task = Task { try await cli.run(["-c", "echo $$ > '\(file.path)'; exec sleep 30"]) }
        let pid = try await pid(in: file)
        XCTAssertTrue(isAlive(pid))

        let started = Date()
        task.cancel()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch let error as EngineError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertFalse(isAlive(pid))
    }

    func testProcessIgnoringSIGTERMIsKilled() async throws {
        let file = tempFile()
        let cli = ContainerCLI(binaryPath: sh)
        let task = Task {
            try await cli.run(["-c", "trap '' TERM; echo $$ > '\(file.path)'; while true; do sleep 0.1; done"])
        }
        let pid = try await pid(in: file)
        task.cancel()
        _ = try? await task.value
        // SIGKILL follows SIGTERM after the grace period.
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(isAlive(pid))
    }

    func testQueryTimeout() async throws {
        let cli = ContainerCLI(binaryPath: sh, queryTimeout: .milliseconds(300))
        let started = Date()
        do {
            _ = try await cli.data(["-c", "sleep 30"])
            XCTFail("expected timeout")
        } catch let error as EngineError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testActionsHaveNoTimeout() async throws {
        let cli = ContainerCLI(binaryPath: sh, queryTimeout: .milliseconds(100))
        try await cli.run(["-c", "sleep 0.4"])
    }

    func testStderrFloodDoesNotDeadlock() async throws {
        // 2 MB of stderr would fill the pipe and hang the child if not drained.
        let data = try await ContainerCLI(binaryPath: sh)
            .data(["-c", "head -c 2000000 /dev/zero | tr '\\0' x >&2; echo done"])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "done\n")
    }

    func testStdinIsDelivered() async throws {
        let file = tempFile()
        try await ContainerCLI(binaryPath: sh).run(["-c", "cat > '\(file.path)'"], input: Data("secret\n".utf8))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "secret\n")
    }

    func testMissingBinary() async throws {
        do {
            _ = try await ContainerCLI(binaryPath: "/nonexistent/container").data(["ls"])
            XCTFail("expected failure")
        } catch let error as EngineError {
            XCTAssertEqual(error, .binaryMissing("/nonexistent/container"))
        }
    }

    // MARK: - Streams

    func testStreamYieldsLinesAndFinishes() async throws {
        var lines: [String] = []
        for try await line in CLIStream(binaryPath: sh).lines(["-c", "echo a; echo b; printf c"]) {
            lines.append(line)
        }
        XCTAssertEqual(lines, ["a", "b", "c"])
    }

    func testStreamFailureCarriesStderr() async throws {
        do {
            for try await _ in CLIStream(binaryPath: sh).lines(["-c", "echo out; echo broken >&2; exit 2"]) {}
            XCTFail("expected failure")
        } catch let error as EngineError {
            XCTAssertEqual(error, .commandFailed(exitCode: 2, message: "broken"))
        }
    }

    func testStreamMergesStderr() async throws {
        var lines: [String] = []
        for try await line in CLIStream(binaryPath: sh).lines(["-c", "echo one >&2; echo two"], mergeStderr: true) {
            lines.append(line)
        }
        XCTAssertEqual(Set(lines), ["one", "two"])
    }

    func testStreamSurvivesStderrFlood() async throws {
        var lines: [String] = []
        let script = "head -c 2000000 /dev/zero | tr '\\0' x >&2; echo done"
        for try await line in CLIStream(binaryPath: sh).lines(["-c", script]) {
            lines.append(line)
        }
        XCTAssertEqual(lines, ["done"])
    }

    /// Breaking out of the loop releases the stream, which stops the process.
    /// (A stream kept alive elsewhere is only stopped by task cancellation.)
    func testConsumerBreakStopsProcess() async throws {
        let file = tempFile()
        let script = "echo $$ > '\(file.path)'; while true; do echo tick; sleep 0.05; done"
        let task = Task { [sh] in
            var count = 0
            for try await _ in CLIStream(binaryPath: sh).lines(["-c", script]) {
                count += 1
                if count == 3 { break }
            }
            return count
        }
        let count = try await task.value
        XCTAssertEqual(count, 3)
        let pid = try await pid(in: file)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(isAlive(pid))
    }

    /// How SwiftUI `.task` ends a stream: the consuming task is cancelled.
    func testConsumerTaskCancellationStopsProcess() async throws {
        let file = tempFile()
        let script = "echo $$ > '\(file.path)'; while true; do echo tick; sleep 0.05; done"
        let stream = CLIStream(binaryPath: sh).lines(["-c", script])
        let task = Task {
            for try await _ in stream {}
        }
        let pid = try await pid(in: file)
        task.cancel()
        try await task.value   // a cancelled stream finishes without error
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(isAlive(pid))
    }

    func testExternalSignalIsAFailureNotSuccess() async throws {
        do {
            for try await _ in CLIStream(binaryPath: sh).lines(["-c", "kill -TERM $$"]) {}
            XCTFail("expected failure")
        } catch let error as EngineError {
            guard case .terminated(let signal, _) = error else {
                return XCTFail("expected .terminated, got \(error)")
            }
            XCTAssertEqual(signal, SIGTERM)
        }
    }
}
