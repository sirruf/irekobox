import Foundation

/// A diagnostic produced while translating a Docker command.
public struct MigrationWarning: Sendable, Hashable {
    public enum Severity: String, Sendable {
        case info        // ignored / handled elsewhere
        case partial     // mapped with reduced fidelity
        case unsupported // no analog in `container`; dropped
    }

    /// The Docker flag this is about (without leading dashes), e.g. `privileged`.
    public let flag: String
    public let message: String
    public let severity: Severity

    public init(flag: String, message: String, severity: Severity) {
        self.flag = flag
        self.message = message
        self.severity = severity
    }
}

/// Result of translating `docker run …` into a `container run …` invocation.
public struct DockerRunTranslation: Sendable, Hashable {
    /// `container` argv, starting with `run`.
    public let arguments: [String]
    public let image: String
    public let warnings: [MigrationWarning]

    public init(arguments: [String], image: String, warnings: [MigrationWarning]) {
        self.arguments = arguments
        self.image = image
        self.warnings = warnings
    }

    /// `container run …` for display / copy.
    public var displayCommand: String {
        (["container"] + arguments).joined(separator: " ")
    }
}

public enum DockerRunError: Error, LocalizedError {
    case noImage

    public var errorDescription: String? {
        switch self {
        case .noImage: return String(localized: "No image found in the command.")
        }
    }
}
