import Foundation

/// Thin async wrapper around the `container` CLI binary.
///
/// One-shot commands run a ``ManagedProcess``, drain stdout/stderr concurrently
/// to avoid pipe-buffer deadlocks, and classify the outcome into an
/// ``EngineError``. Cancelling the calling task stops the process; queries
/// (`data`/`decode`) also stop after ``queryTimeout``. Streaming commands
/// (`logs -f`, `build`, `push`) live in ``CLIStream``.
public actor ContainerCLI {
    public static let defaultBinaryPath = "/usr/local/bin/container"

    /// Keep at most this much stderr per command (the tail is what matters).
    static let stderrLimit = 64 * 1024

    public let binaryPath: String
    /// Time limit for queries (`data`/`decode`); actions (`run`) are unbounded,
    /// since pulls and starts can legitimately take minutes.
    public let queryTimeout: Duration?

    public init(binaryPath: String = ContainerCLI.defaultBinaryPath,
                queryTimeout: Duration? = .seconds(30)) {
        self.binaryPath = binaryPath
        self.queryTimeout = queryTimeout
    }

    /// Shared JSON decoder. `container` emits ISO-8601 timestamps; models keep
    /// raw date strings, so no custom date strategy is required here.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    /// Run a command and return raw stdout bytes. Throws ``EngineError`` on failure.
    public func data(_ arguments: [String]) async throws -> Data {
        try await execute(arguments, timeout: queryTimeout)
    }

    /// Run a command and decode stdout into `T`. `alsoAccepting` lists exit
    /// codes whose stdout is still an answer (e.g. `system status` exits 1
    /// with `{"status":"unregistered"}` when the engine is stopped).
    public func decode<T: Decodable & Sendable>(
        _ type: T.Type,
        _ arguments: [String],
        alsoAccepting exitCodes: Set<Int32>
    ) async throws -> T {
        let data = try await execute(arguments, timeout: queryTimeout, acceptedExitCodes: exitCodes)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw EngineError.decoding(String(describing: error))
        }
    }

    /// Run a command that produces no parseable output (an action).
    ///
    /// `workingDirectory` sets the process CWD so relative paths (e.g. a compose
    /// build context or bind-mount source) resolve against the compose file's
    /// folder rather than the app's.
    public func run(_ arguments: [String], workingDirectory: URL? = nil) async throws {
        _ = try await execute(arguments, workingDirectory: workingDirectory)
    }

    /// Run a command feeding `input` to its stdin — used for `--password-stdin`,
    /// so the secret never appears in argv (and thus not in `ps`).
    public func run(_ arguments: [String], input: Data, workingDirectory: URL? = nil) async throws {
        _ = try await execute(arguments, stdin: input, workingDirectory: workingDirectory)
    }

    // MARK: - Process execution

    private func execute(_ arguments: [String], stdin: Data? = nil,
                         workingDirectory: URL? = nil, timeout: Duration? = nil,
                         acceptedExitCodes: Set<Int32> = []) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw EngineError.binaryMissing(binaryPath)
        }
        let managed = ManagedProcess(binaryPath: binaryPath, arguments: arguments,
                                     workingDirectory: workingDirectory)
        return try await withTaskCancellationHandler {
            try await Self.output(of: managed, stdin: stdin, timeout: timeout, acceptedExitCodes: acceptedExitCodes)
        } onCancel: {
            managed.stop(.cancelled)
        }
    }

    private static func output(of managed: ManagedProcess, stdin: Data?,
                               timeout: Duration?, acceptedExitCodes: Set<Int32> = []) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let process = managed.process
            let inPipe: Pipe? = stdin != nil ? Pipe() : nil
            if let inPipe { process.standardInput = inPipe }

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let stdout = DataAccumulator()
            let stderr = DataAccumulator(limit: stderrLimit)

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                stdout.append(handle.availableData)
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                stderr.append(handle.availableData)
            }

            process.terminationHandler = { _ in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil

                stdout.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                stderr.append(errPipe.fileHandleForReading.readDataToEndOfFile())

                if let failure = managed.failure(stderr: stderr.snapshot()),
                   !managed.exitedNormally(withOneOf: acceptedExitCodes) {
                    continuation.resume(throwing: failure)
                } else {
                    continuation.resume(returning: stdout.snapshot())
                }
            }

            do {
                try managed.launch()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            managed.scheduleTimeout(timeout)

            if let inPipe, let stdin {
                // Write off the caller's thread: a child that doesn't read stdin
                // must not block us once the pipe buffer fills.
                DispatchQueue.global().async {
                    let handle = inPipe.fileHandleForWriting
                    try? handle.write(contentsOf: stdin)
                    try? handle.close()
                }
            }
        }
    }
}
