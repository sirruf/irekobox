import Foundation

/// Runs an arbitrary external binary (e.g. the `docker` CLI) and captures output.
/// `ContainerKit.ContainerCLI` handles the `container` binary; this is for others.
enum ProcessRunner {
    enum RunError: Error, LocalizedError {
        case notExecutable(String)
        case launchFailed(String)
        case failed(exitCode: Int32, message: String)

        var errorDescription: String? {
            switch self {
            case .notExecutable(let path): return String(localized: "Not executable: \(path)")
            case .launchFailed(let reason): return String(localized: "Failed to launch: \(reason)")
            case .failed(let code, let message):
                return message.isEmpty ? String(localized: "Command failed (exit \(String(code))).") : message
            }
        }
    }

    @discardableResult
    static func run(executable: String, _ arguments: [String], environment: [String: String] = [:],
                    workingDirectory: URL? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                continuation.resume(throwing: RunError.notExecutable(executable))
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            }
            if let workingDirectory { process.currentDirectoryURL = workingDirectory }

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let out = ByteBox()
            let err = ByteBox()
            outPipe.fileHandleForReading.readabilityHandler = { out.append($0.availableData) }
            errPipe.fileHandleForReading.readabilityHandler = { err.append($0.availableData) }

            process.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                out.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                err.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                let stdout = String(data: out.snapshot(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: stdout)
                } else {
                    let stderr = String(data: err.snapshot(), encoding: .utf8) ?? ""
                    continuation.resume(throwing: RunError.failed(
                        exitCode: proc.terminationStatus,
                        message: stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }

            do { try process.run() }
            catch { continuation.resume(throwing: RunError.launchFailed(error.localizedDescription)) }
        }
    }
}

private final class ByteBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); data.append(chunk); lock.unlock()
    }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// Locates the Docker CLI and lists local Docker images.
enum DockerEnvironment {
    private static let candidates = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
    ]

    static func dockerPath() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// A local Docker image (parsed from `docker image ls --format '{{json .}}'`).
struct DockerImage: Identifiable, Hashable, Codable {
    let repository: String
    let tag: String
    let id: String
    let size: String

    enum CodingKeys: String, CodingKey {
        case repository = "Repository"
        case tag = "Tag"
        case id = "ID"
        case size = "Size"
    }

    var reference: String { "\(repository):\(tag)" }
    var isValid: Bool { repository != "<none>" && tag != "<none>" }
}

/// A local Docker named volume (from `docker volume ls --format '{{json .}}'`).
struct DockerVolume: Identifiable, Hashable, Codable {
    let name: String
    let driver: String
    let mountpoint: String

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case driver = "Driver"
        case mountpoint = "Mountpoint"
    }

    var id: String { name }
}
