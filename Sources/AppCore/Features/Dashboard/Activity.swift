import Foundation
import ContainerKit
import EngineCore

/// One line of the Overview's Activity: what changed, when.
struct ActivityEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let tone: Tone
    let title: String
    let detail: String

    /// The entry for `event`, or `nil` for what nobody needs to read
    /// (the builder, a resource's first load).
    static func make(_ event: EngineEvent, old: EngineSnapshot, new: EngineSnapshot,
                     at date: Date = Date()) -> ActivityEntry? {
        func entry(_ tone: Tone, _ title: String, _ detail: String) -> ActivityEntry {
            ActivityEntry(date: date, tone: tone, title: title, detail: detail)
        }
        let oldContainers = old.containers.value
        let newContainers = new.containers.value ?? []
        func container(_ id: String) -> Container? {
            newContainers.first { $0.id == id } ?? oldContainers?.first { $0.id == id }
        }
        /// "web" in shop, "ubuntu" as a machine, else the container's name.
        func describe(_ container: Container) -> (name: String, detail: String) {
            if container.isMachine { return (container.machineName ?? container.id, String(localized: "Machine")) }
            if let project = ContainerList.project(of: container) {
                return (container.id, "\(project) · \(container.imageShortName)")
            }
            return (container.id, container.imageShortName)
        }

        switch event {
        case .servicesStarted:
            return entry(.positive, String(localized: "Engine started"), String(localized: "container services are up"))
        case .servicesStopped:
            return entry(.neutral, String(localized: "Engine stopped"), String(localized: "Containers aren't running"))
        case .containerCreated(let id):
            guard oldContainers != nil, let found = container(id), !found.isBuilder else { return nil }
            let (name, detail) = describe(found)
            return entry(.info, String(localized: "\(name) created"), detail)
        case .containerRemoved(let id):
            guard let found = container(id), !found.isBuilder else { return nil }
            let (name, detail) = describe(found)
            return entry(.neutral, String(localized: "\(name) removed"), detail)
        case .containerStateChanged(let id, let from, let to):
            guard oldContainers != nil, let found = container(id), !found.isBuilder else { return nil }
            let (name, detail) = describe(found)
            switch to {
            case .running: return entry(.positive, String(localized: "\(name) started"), detail)
            case .stopped where from.isRunning: return entry(.neutral, String(localized: "\(name) stopped"), detail)
            default: return nil
            }
        case .imageAdded(let reference):
            guard old.images.value != nil else { return nil }
            return entry(.info, String(localized: "\(Self.short(reference)) added"), String(localized: "Image"))
        case .imageRemoved(let reference):
            return entry(.neutral, String(localized: "\(Self.short(reference)) removed"), String(localized: "Image"))
        case .volumeAdded(let name):
            guard old.volumes.value != nil else { return nil }
            return entry(.info, String(localized: "Volume \(name) created"), String(localized: "Volume"))
        case .volumeRemoved(let name):
            return entry(.neutral, String(localized: "Volume \(name) removed"), String(localized: "Volume"))
        case .networkAdded(let name):
            guard old.networks.value != nil else { return nil }
            return entry(.info, String(localized: "Network \(name) created"), String(localized: "Network"))
        case .networkRemoved(let name):
            return entry(.neutral, String(localized: "Network \(name) removed"), String(localized: "Network"))
        }
    }

    /// Health changes: "api is unhealthy", "api is healthy again".
    static func health(old: [String: String], new: [String: String], at date: Date = Date()) -> [ActivityEntry] {
        new.keys.sorted().compactMap { name in
            let status = new[name], before = old[name]
            guard status != before else { return nil }
            switch status {
            case "unhealthy":
                return ActivityEntry(date: date, tone: .critical, title: String(localized: "\(name) is unhealthy"),
                                     detail: String(localized: "Its health check fails"))
            case "healthy" where before == "unhealthy":
                return ActivityEntry(date: date, tone: .positive, title: String(localized: "\(name) is healthy again"),
                                     detail: String(localized: "Its health check passes"))
            default:
                return nil
            }
        }
    }

    /// `docker.io/library/postgres:17` → `postgres:17`.
    static func short(_ reference: String) -> String {
        var name = reference
        for prefix in ["docker.io/library/", "docker.io/"] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
            break
        }
        return name
    }
}

private extension Container {
    /// The BuildKit builder `container` runs for builds.
    var isBuilder: Bool { configuration.labels["com.apple.container.resource.role"] != nil }
}
