import Foundation
import ComposeKit

/// Result of executing a single ``PlanStep``.
public struct StepOutcome: Sendable, Hashable, Identifiable {
    public enum Status: Sendable, Hashable {
        case succeeded
        case skipped(reason: String)
        case failed(message: String)

        public var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    public let step: PlanStep
    public let status: Status

    public var id: UUID { step.id }
}

public extension Array where Element == StepOutcome {
    /// `true` if no step failed.
    var allSucceeded: Bool { !contains { $0.status.isFailure } }
}
