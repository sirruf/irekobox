import Foundation

/// Something about a container worth telling the user: the background agent
/// records these, the app turns them into notifications.
public struct ContainerAlert: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A service exited with an error (not stopped by hand).
        case died
        /// Its restart policy gave up (on-failure limit reached).
        case gaveUp
        /// Its health check started failing.
        case unhealthy
        /// Healthy again after being unhealthy.
        case recovered
    }

    /// Increasing; clients ask for alerts after the last one they saw.
    public let sequence: UInt64
    public let time: Date
    public let kind: Kind
    /// Container name (its ID in `container`).
    public let container: String
    public let detail: String

    public var id: UInt64 { sequence }

    public init(sequence: UInt64, time: Date, kind: Kind, container: String, detail: String) {
        self.sequence = sequence
        self.time = time
        self.kind = kind
        self.container = container
        self.detail = detail
    }
}
