import Foundation

/// Owns one child process: launch, stop (SIGTERM, then SIGKILL after a grace
/// period) and the reason it was stopped. Shared by one-shot commands
/// (``ContainerCLI``) and streams (``CLIStream``).
///
/// A stop requested before launch prevents the launch, so cancellation can never
/// leave an orphaned process behind.
final class ManagedProcess: @unchecked Sendable {
    enum StopReason: Sendable { case cancelled, timedOut }

    /// How long a process gets to exit after SIGTERM before it is SIGKILLed.
    static let killGracePeriod: DispatchTimeInterval = .seconds(2)

    let process = Process()
    private let lock = NSLock()
    private var launched = false
    private var _stopReason: StopReason?

    init(binaryPath: String, arguments: [String], workingDirectory: URL? = nil) {
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
    }

    var stopReason: StopReason? {
        lock.lock(); defer { lock.unlock() }
        return _stopReason
    }

    /// Launch the process. Throws ``EngineError/cancelled`` if a stop was
    /// requested first, or ``EngineError/launchFailed(_:)``.
    func launch() throws {
        lock.lock(); defer { lock.unlock() }
        if let reason = _stopReason {
            throw reason == .cancelled ? EngineError.cancelled : EngineError.timedOut
        }
        do {
            try process.run()
            launched = true
        } catch {
            throw EngineError.launchFailed(error.localizedDescription)
        }
    }

    /// Stop the process for `reason`. Idempotent: the first reason wins.
    func stop(_ reason: StopReason) {
        lock.lock()
        guard _stopReason == nil else { lock.unlock(); return }
        _stopReason = reason
        let shouldSignal = launched && process.isRunning
        lock.unlock()

        guard shouldSignal else { return }
        process.terminate()
        let pid = process.processIdentifier
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGracePeriod) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// Stop with `.timedOut` after `timeout`, unless the process exits first.
    func scheduleTimeout(_ timeout: Duration?) {
        guard let timeout else { return }
        let nanos = timeout.components.seconds * 1_000_000_000
            + timeout.components.attoseconds / 1_000_000_000
        DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanos))) { [weak self] in
            guard let self, self.process.isRunning else { return }
            self.stop(.timedOut)
        }
    }

    /// The error for a finished process, or `nil` on a clean exit.
    /// Ran to completion (not stopped, not killed by a signal) with one of `codes`.
    func exitedNormally(withOneOf codes: Set<Int32>) -> Bool {
        stopReason == nil && process.terminationReason == .exit && codes.contains(process.terminationStatus)
    }

    func failure(stderr: Data) -> EngineError? {
        switch stopReason {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case nil: break
        }
        let status = process.terminationStatus
        if process.terminationReason == .uncaughtSignal {
            return .terminated(signal: status,
                               message: String(decoding: stderr, as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return status == 0 ? nil : EngineError.from(exitCode: status, stderr: stderr)
    }
}

/// Thread-safe byte accumulator for concurrent pipe draining. With `limit`, only
/// the last `limit` bytes are kept (used for stderr, which can be unbounded).
final class DataAccumulator: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    private let limit: Int?

    init(limit: Int? = nil) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if let limit, data.count > limit {
            data.removeFirst(data.count - limit)
        }
    }

    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}
