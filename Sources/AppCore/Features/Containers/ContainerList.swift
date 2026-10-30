import Foundation
import ContainerKit

/// Pure list logic for the Containers screen: filtering, grouping by compose
/// project, and the bits of a container the UI derives (secrets, commands).
enum ContainerList {
    enum StateFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case running = "Running"
        case stopped = "Stopped"
        var id: String { rawValue }
    }

    /// Labels that name the compose project a container belongs to: ours, and
    /// the one Docker Compose writes (for containers created via the socket).
    static let projectLabels = [StackLabel.key, "com.docker.compose.project"]

    static func project(of container: Container) -> String? {
        projectLabels.lazy.compactMap { container.configuration.labels[$0] }.first
    }

    struct Group: Identifiable, Equatable {
        /// `nil` for containers outside any project.
        let project: String?
        let containers: [Container]
        /// Containers `container` runs itself: machines, cluster nodes, the
        /// image builder (only there when system containers are shown).
        var system = false

        var id: String { system ? "\u{0}system" : project ?? "" }
        var title: String { project ?? String(localized: "Standalone") }
        var running: Int { containers.filter { $0.state.isRunning }.count }
    }

    /// Containers matching the search text, state filter and system toggle.
    static func filter(_ containers: [Container], search: String, state: StateFilter,
                       includeSystem: Bool) -> [Container] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return containers.filter { container in
            if !includeSystem && container.isSystem { return false }
            switch state {
            case .all: break
            case .running: guard container.state.isRunning else { return false }
            case .stopped: guard !container.state.isRunning else { return false }
            }
            guard !query.isEmpty else { return true }
            return searchableText(container).contains(query)
        }
    }

    private static func searchableText(_ container: Container) -> String {
        let ports = (container.configuration.publishedPorts ?? []).map { ":\($0.hostPort) \($0.hostPort)" }
        return ([container.id, container.configuration.image.reference, project(of: container) ?? "",
                 container.ipv4Address ?? ""] + ports)
            .joined(separator: " ").lowercased()
    }

    /// Projects first (alphabetically), then standalone containers; the given
    /// order is kept inside each group.
    static func group(_ containers: [Container]) -> [Group] {
        var byProject: [String: [Container]] = [:]
        var standalone: [Container] = []
        var system: [Container] = []
        for container in containers {
            if let project = project(of: container) {
                byProject[project, default: []].append(container)
            } else if container.isSystem {
                system.append(container)
            } else {
                standalone.append(container)
            }
        }
        var groups = byProject.keys.sorted().map { Group(project: $0, containers: byProject[$0]!) }
        if !standalone.isEmpty { groups.append(Group(project: nil, containers: standalone)) }
        if !system.isEmpty { groups.append(Group(project: nil, containers: system, system: true)) }
        return groups
    }

    // MARK: - Environment

    private static let secretKeyMarkers = ["PASSWORD", "PASSWD", "SECRET", "TOKEN", "API_KEY", "PRIVATE_KEY", "CREDENTIAL"]

    /// `KEY=value` with secrets masked: values of secret-looking keys, and
    /// passwords embedded in URLs (`postgres://user:pass@host`).
    static func maskedEnvironment(_ entry: String) -> String {
        guard let equals = entry.firstIndex(of: "=") else { return entry }
        let key = String(entry[..<equals])
        let value = String(entry[entry.index(after: equals)...])
        if secretKeyMarkers.contains(where: { key.uppercased().contains($0) }), !value.isEmpty {
            return "\(key)=••••••"
        }
        return "\(key)=\(maskURLPassword(value))"
    }

    static func maskURLPassword(_ value: String) -> String {
        guard let scheme = value.range(of: "://"),
              let at = value[scheme.upperBound...].firstIndex(of: "@") else { return value }
        let userInfo = value[scheme.upperBound..<at]
        guard let colon = userInfo.firstIndex(of: ":") else { return value }
        return String(value[..<value.index(after: colon)]) + "••••••" + String(value[at...])
    }

    /// A `container run …` command that recreates this container, for copying.
    static func runCommand(_ container: Container) -> String {
        let arguments = ContainerRecreate.runArguments(for: container,
                                                       edits: ContainerRecreate.currentEdits(for: container))
        return (["container"] + arguments.map(shellQuoted)).joined(separator: " ")
    }

    static func shellQuoted(_ argument: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=@,+%"))
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy(safe.contains) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
