import Foundation
import Observation
import ContainerKit

/// Structured, validated editing state for a container's recreate settings.
@MainActor
@Observable
final class EditContainerModel {
    struct EnvRow: Identifiable, Hashable { let id = UUID(); var key = ""; var value = "" }
    struct PortRow: Identifiable, Hashable { let id = UUID(); var host = ""; var container = ""; var proto = "tcp" }
    struct VolumeRow: Identifiable, Hashable { let id = UUID(); var source = ""; var destination = ""; var readOnly = false }
    struct NetworkRow: Identifiable, Hashable { let id = UUID(); var name = "" }

    var env: [EnvRow] = []
    var ports: [PortRow] = []
    var volumes: [VolumeRow] = []
    var networks: [NetworkRow] = []
    var cpus = 1
    var memoryMiB: Int64 = 1024
    private var originalCPUs = 1
    private var originalMemory: Int64 = 1024
    /// The settings as the container runs now, to count changes against.
    private var original = ContainerEdits(environment: [], ports: [], volumes: [], networks: [])

    init(container: Container) {
        let config = container.configuration
        env = config.initProcess.environment.map { entry in
            if let eq = entry.firstIndex(of: "=") {
                return EnvRow(key: String(entry[..<eq]), value: String(entry[entry.index(after: eq)...]))
            }
            return EnvRow(key: entry, value: "")
        }
        ports = (config.publishedPorts ?? []).map {
            PortRow(host: "\($0.hostPort)", container: "\($0.containerPort)", proto: $0.proto ?? "tcp")
        }
        volumes = (config.mounts ?? []).map {
            VolumeRow(source: $0.volumeName ?? $0.source ?? "", destination: $0.destination, readOnly: $0.isReadOnly)
        }
        networks = config.networks.map { NetworkRow(name: $0.network) }
        cpus = config.resources.cpus
        memoryMiB = max(1, config.resources.memoryInBytes / (1024 * 1024))
        originalCPUs = cpus
        originalMemory = memoryMiB
        original = buildEdits()
    }

    /// Settings added, removed or changed since the sheet opened (a changed
    /// value counts once).
    var changeCount: Int {
        let now = buildEdits()
        func changed(_ a: [String], _ b: [String], key: (String) -> String = { $0 }) -> Int {
            let before = Dictionary(a.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
            let after = Dictionary(b.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
            return Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.count
        }
        let variable: (String) -> String = { String($0.prefix { $0 != "=" }) }
        return (cpus == originalCPUs ? 0 : 1) + (memoryMiB == originalMemory ? 0 : 1)
            + changed(original.environment, now.environment, key: variable)
            + changed(original.ports, now.ports)
            + changed(original.volumes, now.volumes)
            + changed(original.networks, now.networks)
    }

    // MARK: - Blank detection (blank rows are ignored, not errors)

    static func isBlank(_ r: EnvRow) -> Bool { r.key.isEmpty && r.value.isEmpty }
    static func isBlank(_ r: PortRow) -> Bool { r.host.isEmpty && r.container.isEmpty }
    static func isBlank(_ r: VolumeRow) -> Bool { r.source.isEmpty && r.destination.isEmpty }
    static func isBlank(_ r: NetworkRow) -> Bool { r.name.isEmpty }

    // MARK: - Validation

    func envError(_ r: EnvRow) -> String? {
        if Self.isBlank(r) { return nil }
        return Self.isValidEnvName(r.key) ? nil : String(localized: "Invalid variable name")
    }
    func portError(_ r: PortRow) -> String? {
        if Self.isBlank(r) { return nil }
        if !Self.isValidPort(r.host) { return String(localized: "Host port must be 1–65535") }
        if !Self.isValidPort(r.container) { return String(localized: "Container port must be 1–65535") }
        return nil
    }
    func volumeError(_ r: VolumeRow) -> String? {
        if Self.isBlank(r) { return nil }
        if r.source.isEmpty { return String(localized: "Source is required") }
        if !r.destination.hasPrefix("/") { return String(localized: "Destination must be an absolute path") }
        return nil
    }
    func networkError(_ r: NetworkRow) -> String? {
        if Self.isBlank(r) { return nil }
        return r.name.contains(" ") ? String(localized: "Name can't contain spaces") : nil
    }

    var isValid: Bool {
        env.allSatisfy { envError($0) == nil }
            && ports.allSatisfy { portError($0) == nil }
            && volumes.allSatisfy { volumeError($0) == nil }
            && networks.allSatisfy { networkError($0) == nil }
    }

    static func isValidEnvName(_ s: String) -> Bool {
        guard let first = s.first, first.isLetter || first == "_" else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
    static func isValidPort(_ s: String) -> Bool {
        guard let n = Int(s) else { return false }
        return (1...65535).contains(n)
    }

    // MARK: - Build

    func buildEdits() -> ContainerEdits {
        ContainerEdits(
            environment: env.filter { !Self.isBlank($0) }.map { "\($0.key)=\($0.value)" },
            ports: ports.filter { !Self.isBlank($0) }.map { row in
                row.proto == "tcp" ? "\(row.host):\(row.container)" : "\(row.host):\(row.container)/\(row.proto)"
            },
            volumes: volumes.filter { !Self.isBlank($0) }.map { row in
                "\(row.source):\(row.destination)" + (row.readOnly ? ":ro" : "")
            },
            networks: networks.filter { !Self.isBlank($0) }.map(\.name),
            cpus: cpus,
            memoryMiB: memoryMiB
        )
    }
}
