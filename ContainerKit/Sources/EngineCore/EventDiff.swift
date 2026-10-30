import Foundation
import ContainerKit

/// Derives ``EngineEvent``s by comparing consecutive lists. No events are
/// produced for the first load of a resource (`old == nil`): everything would
/// look "created".
enum EventDiff {
    static func containers(old: [Container]?, new: [Container]) -> [EngineEvent] {
        guard let old else { return [] }
        let before = Dictionary(old.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(new.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        var events: [EngineEvent] = []
        for container in new {
            guard let previous = before[container.id] else {
                events.append(.containerCreated(id: container.id))
                continue
            }
            if previous != container.state {
                events.append(.containerStateChanged(id: container.id, from: previous, to: container.state))
            }
        }
        for container in old where after[container.id] == nil {
            events.append(.containerRemoved(id: container.id))
        }
        return events
    }

    static func names(old: [String]?, new: [String],
                      added: (String) -> EngineEvent, removed: (String) -> EngineEvent) -> [EngineEvent] {
        guard let old else { return [] }
        let before = Set(old), after = Set(new)
        return new.filter { !before.contains($0) }.map(added)
            + old.filter { !after.contains($0) }.map(removed)
    }
}
