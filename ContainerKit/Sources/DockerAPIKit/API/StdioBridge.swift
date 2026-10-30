import Foundation
import Darwin
import ContainerKit

/// Pipes between a hijacked client connection and a process in a container.
/// The process gets one end of each pipe (through the apiserver, which keeps
/// duplicates); we pump the other ends: client bytes → stdin, stdout/stderr →
/// client, framed as Docker's multiplexed stream unless it is a TTY.
final class StdioBridge: @unchecked Sendable {
    let tty: Bool
    private let stdinPipe: (read: Int32, write: Int32)?
    private let stdoutPipe: (read: Int32, write: Int32)?
    private let stderrPipe: (read: Int32, write: Int32)?
    private let lock = NSLock()
    private var containerEndsClosed = false
    private var started = false

    /// How long an attached client that sent EOF may wait for `start`.
    static let startGrace: Duration = .seconds(30)

    init(stdin: Bool, stdout: Bool, stderr: Bool, tty: Bool) {
        self.tty = tty
        stdinPipe = stdin ? Self.makePipe() : nil
        stdoutPipe = stdout ? Self.makePipe() : nil
        // A TTY has one output stream.
        stderrPipe = stderr && !tty ? Self.makePipe() : nil
    }

    /// The ends for the process.
    var stdio: ProcessStdio {
        ProcessStdio(stdin: stdinPipe?.read, stdout: stdoutPipe?.write, stderr: stderrPipe?.write)
    }

    /// After the apiserver has its duplicates: drop ours, so EOF flows when
    /// the process ends.
    func closeContainerEnds() {
        lock.withLock {
            guard !containerEndsClosed else { return }
            containerEndsClosed = true
            if let fd = stdinPipe?.read { close(fd) }
            if let fd = stdoutPipe?.write { close(fd) }
            if let fd = stderrPipe?.write { close(fd) }
        }
    }

    func markStarted() {
        lock.withLock { started = true }
    }

    /// Pump until the process's output ends (or, if it never starts, until
    /// the client leaves).
    func run(on connection: HijackedConnection) async {
        let stdinWrite = stdinPipe?.write
        let input = Task {
            for await data in connection.input {
                guard let fd = stdinWrite else { continue }
                Self.writeAll(fd, data)
            }
            if let fd = stdinWrite { close(fd) }     // stdin EOF for the process
            // A client without stdin half-closes right away, before `start`:
            // that's not leaving. Only if no start comes do we give up and
            // unblock the readers.
            if !self.lock.withLock({ self.started }) {
                try? await Task.sleep(for: Self.startGrace)
                if !self.lock.withLock({ self.started }) { self.closeContainerEnds() }
            }
        }
        await withTaskGroup(of: Void.self) { group in
            if let fd = stdoutPipe?.read {
                group.addTask { await Self.forward(fd, stream: 1, tty: self.tty, to: connection) }
            }
            if let fd = stderrPipe?.read {
                group.addTask { await Self.forward(fd, stream: 2, tty: self.tty, to: connection) }
            }
        }
        if stdoutPipe == nil && stderrPipe == nil {
            // Nothing to show: wait for the client to finish sending.
            await input.value
        }
        _ = input
    }

    // MARK: - Helpers

    private static func makePipe() -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        Darwin.pipe(&fds)
        // Our ends must not leak into processes we spawn.
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        return (fds[0], fds[1])
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }

    /// Read `fd` until EOF on a background thread and send each chunk.
    private static func forward(_ fd: Int32, stream: UInt8, tty: Bool, to connection: HijackedConnection) async {
        let chunks = AsyncStream<Data> { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = [UInt8](repeating: 0, count: 32 << 10)
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    if count > 0 {
                        continuation.yield(Data(buffer[0..<count]))
                    } else if count < 0 && errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
                close(fd)
                continuation.finish()
            }
        }
        for await chunk in chunks {
            try? await connection.write(tty ? chunk : LogsStatsAPI.frame(chunk, stream: stream))
        }
    }
}

/// `docker run -it` attaches before it starts the container: the attach
/// leaves its bridge here and `start` boots the container with it.
public actor AttachRegistry {
    private var pending: [String: StdioBridge] = [:]

    public init() {}

    func register(_ bridge: StdioBridge, for container: String) {
        pending[container] = bridge
    }

    func take(_ container: String) -> StdioBridge? {
        pending.removeValue(forKey: container)
    }

    func remove(_ bridge: StdioBridge, for container: String) {
        if pending[container] === bridge { pending.removeValue(forKey: container) }
    }
}
