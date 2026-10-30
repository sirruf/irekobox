import Foundation

/// Typed errors surfaced by any ``ContainerEngine`` backend (CLI or XPC).
public enum EngineError: Error, LocalizedError, Sendable, Equatable, Codable {
    /// The `container` binary is missing or not executable at the configured path.
    case binaryMissing(String)
    /// The process could not be launched.
    case launchFailed(String)
    /// `container system` services are not running — the precondition for every command.
    case servicesNotRunning
    /// The referenced container/image/volume/network was not found.
    case notFound(String)
    /// The operation conflicts with existing state (already exists, in use).
    case conflict(String)
    /// The command exited non-zero. Carries the exit code and stderr.
    case commandFailed(exitCode: Int32, message: String)
    /// The process was killed by a signal it did not request (not a cancellation).
    case terminated(signal: Int32, message: String)
    /// The apiserver rejected the request (`code` is its error code name).
    case serviceError(code: String, message: String)
    /// Output could not be decoded into the expected model.
    case decoding(String)
    /// Applying changes to a container failed; the previous container was
    /// restored from its old configuration.
    case rolledBack(String)
    /// The caller cancelled the operation; the process was stopped.
    case cancelled
    /// The operation exceeded its time limit; the process was stopped.
    case timedOut

    /// Classify a non-zero exit into a typed error using stderr heuristics.
    static func from(exitCode: Int32, stderr: Data) -> EngineError {
        let message = String(decoding: stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = message.lowercased()

        if lower.contains("connection refused")
            || lower.contains("apiserver")
            || (lower.contains("service") && lower.contains("not running"))
            || lower.contains("could not connect") {
            return .servicesNotRunning
        }
        if lower.contains("not found") || lower.contains("no such") {
            return .notFound(message.isEmpty ? "not found" : message)
        }
        if lower.contains("already exists") || lower.contains("in use") {
            return .conflict(message)
        }
        return .commandFailed(exitCode: exitCode, message: message)
    }

    public var errorDescription: String? {
        switch self {
        case .binaryMissing(let path):
            return String(localized: "The `container` CLI was not found at \(path).")
        case .launchFailed(let reason):
            return String(localized: "Failed to launch `container`: \(reason)")
        case .servicesNotRunning:
            return String(localized: "The engine isn't running. Start it from the Engine menu (or run container system start).")
        case .notFound(let what):
            return what
        case .conflict(let message):
            return message
        case .commandFailed(let code, let message):
            return message.isEmpty ? String(localized: "Command failed (exit \(String(code))).") : message
        case .terminated(let signal, let message):
            return message.isEmpty ? String(localized: "Command was terminated (signal \(String(signal))).") : message
        case .serviceError(_, let message):
            return message
        case .decoding(let detail):
            return String(localized: "Could not decode output: \(detail)")
        case .rolledBack(let reason):
            return String(localized: "Couldn't apply the changes: \(reason) The container was restored with its previous settings.")
        case .cancelled:
            return String(localized: "The operation was cancelled.")
        case .timedOut:
            return String(localized: "The operation timed out.")
        }
    }
}
