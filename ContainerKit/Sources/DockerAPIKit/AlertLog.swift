import Foundation
import ContainerKit

/// The agent's recent alerts (in memory, last 200). Sequence numbers start
/// from the launch time so a client that saw an older agent's alerts never
/// mistakes new ones for seen.
public actor AlertLog {
    private var alerts: [ContainerAlert] = []
    private var next: UInt64

    public init(now: Date = Date()) {
        next = UInt64(now.timeIntervalSince1970 * 1000)
    }

    public func add(_ kind: ContainerAlert.Kind, container: String, detail: String, at time: Date = Date()) {
        next += 1
        alerts.append(ContainerAlert(sequence: next, time: time, kind: kind, container: container, detail: detail))
        if alerts.count > 200 { alerts.removeFirst(alerts.count - 200) }
    }

    /// Alerts after `sequence`, oldest first.
    public func after(_ sequence: UInt64) -> [ContainerAlert] {
        alerts.filter { $0.sequence > sequence }
    }

    /// The newest sequence (a client starts from here to skip the past).
    public var latest: UInt64 { next }
}
