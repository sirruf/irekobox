import XCTest
import Darwin
@testable import ContainerKit

/// Attach/exec plumbing against the live apiserver.
/// IREKOBOX_LIVE_TESTS=1 swift test --filter XPCProcessLiveTests
final class XPCProcessLiveTests: XCTestCase {

    private func pipe() -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        Darwin.pipe(&fds)
        return (fds[0], fds[1])
    }

    private static func readAll(_ fd: Int32) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(fd, &buffer, buffer.count)
                    if n <= 0 { break }
                    data.append(contentsOf: buffer[0..<n])
                }
                close(fd)
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }

    func testBootstrapWithOurPipesAndExec() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IREKOBOX_LIVE_TESTS"] == "1")
        let engine = XPCEngine(fallback: CLIEngine())
        let name = "ib-io-\(UUID().uuidString.prefix(6).lowercased())"
        _ = try await ContainerCLI().data(["create", "--name", name, "-i", "alpine:latest",
                                          "sh", "-c", "read x; echo got $x; echo oops >&2; sleep 3; exit 4"])
        defer { Task { try? await engine.deleteContainer(name, force: true) } }

        let stdin = pipe(), stdout = pipe(), stderr = pipe()
        try await engine.bootstrapContainer(name, stdio: ProcessStdio(stdin: stdin.read, stdout: stdout.write, stderr: stderr.write))
        // The apiserver holds duplicates now.
        close(stdin.read); close(stdout.write); close(stderr.write)
        try await engine.startProcess(name, process: name)

        async let out = Self.readAll(stdout.read)
        async let err = Self.readAll(stderr.read)
        _ = "hello\n".withCString { write(stdin.write, $0, 6) }
        close(stdin.write)

        // exec while it runs
        let execOut = pipe()
        let processID = UUID().uuidString.lowercased()
        try await engine.createProcess(name, process: processID,
                                       spec: ProcessSpec(executable: "sh", arguments: ["-c", "echo from-exec; exit 9"],
                                                         environment: ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"]),
                                       stdio: ProcessStdio(stdout: execOut.write))
        close(execOut.write)
        try await engine.startProcess(name, process: processID)
        let execText = await Self.readAll(execOut.read)
        let execExit = try await engine.waitProcess(name, process: processID)
        print("EXEC out=\(execText.debugDescription) code=\(execExit.code)")

        let exit = try await engine.waitContainer(name)
        let (o, e) = await (out, err)
        print("INIT stdout=\(o.debugDescription) stderr=\(e.debugDescription) code=\(exit.code)")
        XCTAssertEqual(o, "got hello\n")
        XCTAssertEqual(e, "oops\n")
        XCTAssertEqual(exit.code, 4)
        XCTAssertEqual(execText, "from-exec\n")
        XCTAssertEqual(execExit.code, 9)
    }
}
