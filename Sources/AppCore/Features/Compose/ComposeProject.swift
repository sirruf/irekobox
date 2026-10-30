import Foundation
import ContainerKit
import ComposeKit

/// A compose project as the Compose screen shows it: added here (with its
/// compose file) or found on containers that `docker compose` started.
struct ComposeProject: Identifiable, Hashable {
    let name: String
    /// Set when the project was added in this app (we run it ourselves).
    var entry: StackEntry?
    /// The project folder (Docker Compose's `working_dir` label, or the
    /// added compose file's folder).
    var directory: String?
    var configFiles: [String]
    var containers: [Container]

    var id: String { name }
    var isManagedHere: Bool { entry != nil }
    var composePath: String? { entry?.composePath ?? configFiles.first }
    var running: Int { containers.filter { $0.state.isRunning }.count }

    enum Summary: Equatable {
        case notCreated, running, stopped, partial(running: Int, total: Int)
    }

    var summary: Summary {
        if containers.isEmpty { return .notCreated }
        if running == containers.count { return .running }
        if running == 0 { return .stopped }
        return .partial(running: running, total: containers.count)
    }

    // MARK: - Labels

    static let workingDirLabel = "com.docker.compose.project.working_dir"
    static let configFilesLabel = "com.docker.compose.project.config_files"
    static let serviceLabel = "com.docker.compose.service"

    /// Labels our runs add so a project reads the same as one Docker Compose made.
    static func runLabels(for entry: StackEntry) -> [String: String] {
        [StackLabel.key: entry.name,
         workingDirLabel: URL(fileURLWithPath: entry.composePath).deletingLastPathComponent().path,
         configFilesLabel: entry.composePath]
    }

    /// Projects added here plus any other project found on containers;
    /// added ones first, each group by name.
    static func all(entries: [StackEntry], containers: [Container]) -> [ComposeProject] {
        let grouped = Dictionary(grouping: containers.filter { ContainerList.project(of: $0) != nil },
                                 by: { ContainerList.project(of: $0)! })
        var projects = entries.map { entry in
            ComposeProject(name: entry.name, entry: entry,
                           directory: URL(fileURLWithPath: entry.composePath).deletingLastPathComponent().path,
                           configFiles: [entry.composePath], containers: grouped[entry.name] ?? [])
        }
        let added = Set(entries.map(\.name))
        for (name, members) in grouped where !added.contains(name) {
            let labels = members.first?.configuration.labels ?? [:]
            projects.append(ComposeProject(
                name: name, entry: nil, directory: labels[workingDirLabel],
                configFiles: (labels[configFilesLabel] ?? "").split(separator: ",").map(String.init),
                containers: members))
        }
        return projects.sorted { ($0.isManagedHere ? 0 : 1, $0.name) < ($1.isManagedHere ? 0 : 1, $1.name) }
    }

    // MARK: - Services

    /// The project's services: from its compose file when it can be read,
    /// merged with the containers that run them.
    func services(file: ComposeFile?) -> [ComposeService] {
        var byName: [String: ComposeService] = [:]
        for (name, service) in file?.services ?? [:] {
            byName[name] = ComposeService(name: name, definition: service)
        }
        for container in containers {
            let name = serviceName(of: container, known: Set(byName.keys))
            byName[name, default: ComposeService(name: name, definition: nil)].containers.append(container)
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    /// The compose service label, or a name matching `project-service[-n]`
    /// or `container_name` (containers from before the label).
    func serviceName(of container: Container, known: Set<String>) -> String {
        if let label = container.configuration.labels[Self.serviceLabel] { return label }
        let id = container.id
        for service in known.sorted(by: { $0.count > $1.count }) {
            let base = "\(name)-\(service)"
            if id == base || id.hasPrefix(base + "-") { return service }
        }
        return id
    }
}

/// One service of a project.
struct ComposeService: Identifiable, Hashable {
    let name: String
    let definition: Service?
    var containers: [Container] = []

    var id: String { name }

    static func == (a: ComposeService, b: ComposeService) -> Bool {
        a.name == b.name && a.containers == b.containers && a.dependsOn == b.dependsOn
    }

    func hash(into hasher: inout Hasher) { hasher.combine(name) }

    init(name: String, definition: Service?) {
        self.name = name
        self.definition = definition
    }

    var image: String {
        containers.first?.imageShortName ?? definition?.image ?? (definition?.build != nil ? String(localized: "built here") : "")
    }

    var dependsOn: [String] { definition?.dependsOn?.dependencies.map(\.service).sorted() ?? [] }

    var tone: Tone {
        if containers.isEmpty { return .inactive }
        if containers.allSatisfy({ $0.state.isRunning }) { return .positive }
        if containers.contains(where: { $0.state.isRunning }) { return .warning }
        return .neutral
    }

    var stateLabel: String {
        if containers.isEmpty { return String(localized: "Not created") }
        let running = containers.filter { $0.state.isRunning }.count
        if containers.count > 1 { return String(localized: "\(running) of \(containers.count) running") }
        return running == 1 ? String(localized: "Running") : String(localized: "Stopped")
    }

    /// Ports on the Mac: the running containers' own, else what the file asks for.
    var access: [ServiceAccess] {
        let live = containers.flatMap { $0.configuration.publishedPorts ?? [] }.map(PortLink.init)
        var result: [ServiceAccess]
        if !containers.isEmpty {
            var seen: Set<String> = []
            result = live.filter { seen.insert($0.id).inserted }.map { .port($0, live: true) }
        } else {
            result = (definition?.ports ?? []).compactMap { mapping in
                guard let published = mapping.published.flatMap({ Int($0) }), let target = mapping.target else { return nil }
                let port = Container.PublishedPort(containerPort: target, hostPort: published,
                                                   hostAddress: mapping.hostIP, proto: mapping.networkProtocol, count: nil)
                return .port(PortLink(port), live: false)
            }
        }
        for name in containers.flatMap(ContainerPresentation.localNames) where !result.contains(.name(name)) {
            result.append(.name(name))
        }
        return result
    }

    /// Published ports only.
    var ports: [ServiceAccess] { access.filter { if case .port = $0 { return true } else { return false } } }

    /// Local DNS names only.
    var names: [ServiceAccess] { access.filter { if case .name = $0 { return true } else { return false } } }

    /// Volumes and folders it mounts, as short labels.
    var mounts: [ServiceMount] {
        (definition?.volumes ?? []).map { volume in
            ServiceMount(kind: volume.kind == .bind ? .folder : .volume,
                         source: volume.source ?? String(localized: "anonymous", comment: "Mount source: an anonymous volume"), target: volume.target)
        }
    }

    /// Networks it's on: the containers' own, else what the file asks for
    /// (the project's default network when it names none).
    var networks: [String] {
        if !containers.isEmpty {
            return Array(Set(containers.flatMap { $0.configuration.networks.map(\.network) })).sorted()
        }
        let names = definition?.networks?.names ?? []
        return names.isEmpty ? ["default"] : names.sorted()
    }
}

/// A way in from the Mac.
enum ServiceAccess: Hashable, Identifiable {
    /// A published port; `live` when a container publishes it now.
    case port(PortLink, live: Bool)
    /// A local DNS name (`web.shop.test`), any port.
    case name(String)

    var id: String {
        switch self {
        case .port(let port, _): return "port:\(port.id)"
        case .name(let name): return "name:\(name)"
        }
    }

    var title: String {
        switch self {
        case .port(let port, _):
            let host = port.hostAddress ?? "localhost"
            return port.proto == "tcp" ? "\(host):\(port.hostPort)" : "\(host):\(port.hostPort)/\(port.proto)"
        case .name(let name): return name
        }
    }

    var url: URL? {
        switch self {
        case .port(let port, _): return port.url
        case .name(let name): return URL(string: "http://\(name)")
        }
    }
}

struct ServiceMount: Hashable {
    enum Kind { case volume, folder }
    let kind: Kind
    let source: String
    let target: String

    var title: String {
        kind == .folder ? (source as NSString).lastPathComponent : source
    }
}

/// A network's name without the project prefix compose adds
/// (`shop_backend`, `shop-default` → `backend`, `default`).
func shortNetworkName(_ network: String, project: String) -> String {
    for separator in ["_", "-"] where network.hasPrefix(project + separator) {
        return String(network.dropFirst(project.count + 1))
    }
    return network
}

extension PortLink: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
