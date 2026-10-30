import Foundation

/// Streams line-by-line stdout from a long-running `container` command
/// (`logs -f`, `stats`, `system logs -f`).
///
/// Cancelling the consuming `Task` terminates the underlying process.
public struct CLIStream: Sendable {
    public let binaryPath: String

    public init(binaryPath: String = ContainerCLI.defaultBinaryPath) {
        self.binaryPath = binaryPath
    }

    /// Follow container logs: `container logs -f [--boot] <id>`.
    public func logs(_ id: String, follow: Bool = true, boot: Bool = false) -> AsyncThrowingStream<String, Error> {
        var arguments = ["logs"]
        if follow { arguments.append("--follow") }
        if boot { arguments.append("--boot") }
        arguments.append(id)
        return lines(arguments)
    }

    /// Stream resource usage: `container stats <id>`.
    public func stats(_ id: String) -> AsyncThrowingStream<String, Error> {
        lines(["stats", id])
    }

    /// Run `arguments` and yield each line as it arrives. When `mergeStderr` is
    /// set, stderr is interleaved into the same stream — needed for tools that
    /// write progress to stderr (e.g. `build` / `push` with `--progress plain`).
    /// Otherwise stderr is still drained (so a chatty child can't block on a full
    /// pipe) and its tail is attached to the error if the command fails.
    ///
    /// The stream finishes normally on exit 0 or when the consumer stops
    /// iterating (which stops the process); any other exit — including a signal
    /// the consumer didn't cause — finishes with an ``EngineError``.
    /// `environment` is added to this process's environment (e.g. KUBECONFIG).
    public func lines(_ arguments: [String], mergeStderr: Bool = false,
                      environment: [String: String] = [:]) -> AsyncThrowingStream<String, Error> {
        let binaryPath = self.binaryPath
        return AsyncThrowingStream { continuation in
            guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
                continuation.finish(throwing: EngineError.binaryMissing(binaryPath))
                return
            }

            let managed = ManagedProcess(binaryPath: binaryPath, arguments: arguments)
            let process = managed.process
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            }
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let buffer = LineBuffer()
            let errBuffer = LineBuffer()
            let errTail = DataAccumulator(limit: ContainerCLI.stderrLimit)
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                for line in buffer.append(chunk) {
                    continuation.yield(line)
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                if mergeStderr {
                    for line in errBuffer.append(chunk) {
                        continuation.yield(line)
                    }
                } else {
                    errTail.append(chunk)
                }
            }

            process.terminationHandler = { _ in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                for line in buffer.append(outPipe.fileHandleForReading.readDataToEndOfFile()) {
                    continuation.yield(line)
                }
                let errRest = errPipe.fileHandleForReading.readDataToEndOfFile()
                if mergeStderr {
                    for line in errBuffer.append(errRest) {
                        continuation.yield(line)
                    }
                } else {
                    errTail.append(errRest)
                }
                if let tail = buffer.flush() {
                    continuation.yield(tail)
                }
                if mergeStderr, let tail = errBuffer.flush() {
                    continuation.yield(tail)
                }
                switch managed.failure(stderr: errTail.snapshot()) {
                case nil, .cancelled?:
                    continuation.finish()
                case let failure?:
                    continuation.finish(throwing: failure)
                }
            }

            continuation.onTermination = { _ in
                managed.stop(.cancelled)
            }

            do {
                try managed.launch()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

/// Accumulates byte chunks and emits complete newline-delimited lines.
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        var lines: [String] = []
        while let newlineIndex = data.firstIndex(of: 0x0A) {
            let lineData = data[data.startIndex..<newlineIndex]
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
            data.removeSubrange(data.startIndex...newlineIndex)
        }
        return lines
    }

    func flush() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return nil }
        data.removeAll()
        return line.isEmpty ? nil : line
    }
}
