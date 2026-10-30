import Foundation

/// Where the app gets engine state from: an in-process ``EngineStore`` or the
/// background agent's store over XPC (``AgentClient``). Same contract either way.
public protocol EngineStateSource: AnyObject, Sendable {
    /// Snapshots and events, starting with the current snapshot.
    func updates() async -> AsyncStream<EngineUpdate>
    /// Keep `resources` polled until ``removeInterest(_:)``.
    func addInterest(_ resources: Set<EngineResource>) async -> UUID
    func removeInterest(_ token: UUID) async
    /// Fetch now; returns the snapshot including data fetched after the call.
    func refreshSnapshot(_ resources: Set<EngineResource>) async -> EngineSnapshot
    /// Whether any of this client's windows is visible (polling slows otherwise).
    func setVisible(_ visible: Bool) async
    /// Resources currently polled.
    func currentlyPolled() async -> Set<EngineResource>
}

extension EngineStore: EngineStateSource {
    /// Service status first (other resources are skipped while it's unknown or
    /// stopped), then the rest concurrently.
    public func refreshSnapshot(_ resources: Set<EngineResource>) async -> EngineSnapshot {
        if resources.contains(.system) {
            await refresh(.system)
        }
        await refresh(resources.subtracting([.system]))
        return snapshot
    }

    public func setVisible(_ visible: Bool) async {
        setBackground(!visible)
    }

    public func currentlyPolled() async -> Set<EngineResource> {
        polledResources
    }
}
