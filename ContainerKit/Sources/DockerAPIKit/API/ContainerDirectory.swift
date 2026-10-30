import Foundation
import CryptoKit
import ContainerKit

/// A container as Docker clients see it: a 64-hex ID, Docker's lifecycle
/// state, and how it last exited.
public struct DockerContainer: Sendable {
    public enum State: String, Sendable {
        case created, running, exited
    }

    public let container: Container
    public let id: String
    public let state: State
    /// Set for `exited`.
    public let exit: ContainerExit?
    /// Set for a running container with a health check.
    public var health: HealthMonitor.Health? = nil

    public var name: String { container.id }

    /// Stable for the life of a container: its name plus creation time, so a
    /// recreated container with the same name gets a new ID, as in Docker.
    public static func id(for container: Container) -> String {
        let digest = SHA256.hash(data: Data("\(container.id)\u{0}\(container.configuration.creationDate)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Docker's `Status` column: "Up 5 minutes", "Exited (7) 3 minutes ago", "Created".
    public func statusText(now: Date = Date()) -> String {
        switch state {
        case .running:
            let up = container.startedDate.map { "Up \(HumanDuration.string(now.timeIntervalSince($0)))" } ?? "Up"
            switch health?.status {
            case .starting: return up + " (health: starting)"
            case .healthy: return up + " (healthy)"
            case .unhealthy: return up + " (unhealthy)"
            case nil: return up
            }
        case .exited:
            // Unknown when it ended while nothing was watching: say so rather
            // than invent a code.
            guard let exit else { return "Exited" }
            guard let at = exit.exitedAt else { return "Exited (\(exit.code))" }
            return "Exited (\(exit.code)) \(HumanDuration.string(now.timeIntervalSince(at))) ago"
        case .created:
            return "Created"
        }
    }
}

/// Lists and resolves containers for the API, hiding `container`'s own
/// system containers (the BuildKit builder).
public struct ContainerDirectory: Sendable {
    let backend: DockerBackend
    let exits: ExitRecorder?
    let health: HealthMonitor?
    let renames: Renames?

    public init(backend: DockerBackend, exits: ExitRecorder? = nil, health: HealthMonitor? = nil, renames: Renames? = nil) {
        self.backend = backend
        self.exits = exits
        self.health = health
        self.renames = renames
    }

    public func all() async throws -> [DockerContainer] {
        let containers = try await backend.listContainers(all: true).filter { !$0.isSystem }
        return await withTaskGroup(of: DockerContainer.self) { group in
            for container in containers {
                group.addTask { await describe(container) }
            }
            var result: [DockerContainer] = []
            for await item in group { result.append(item) }
            // Newest first, like `docker ps`.
            return result.sorted { $0.container.configuration.creationDate > $1.container.configuration.creationDate }
        }
    }

    /// By full ID, unique ID prefix, name, or "/name".
    public func resolve(_ reference: String) async throws -> DockerContainer {
        let containers = try await backend.listContainers(all: true).filter { !$0.isSystem }
        let name = reference.hasPrefix("/") ? String(reference.dropFirst()) : reference
        if let match = containers.first(where: { $0.id == name }) { return await describe(match) }
        if let match = containers.first(where: { DockerContainer.id(for: $0) == reference }) { return await describe(match) }
        let prefixed = reference.count >= 1 ? containers.filter { DockerContainer.id(for: $0).hasPrefix(reference.lowercased()) } : []
        if prefixed.count > 1 {
            throw DockerAPIError(400, "multiple IDs found with provided prefix: \(reference)")
        }
        if let match = prefixed.first { return await describe(match) }
        // An ID from before a rename (see ContainersAPI.rename).
        if let renamed = await renames?.name(forOldID: reference),
           let match = containers.first(where: { $0.id == renamed }) { return await describe(match) }
        throw DockerAPIError.noSuchContainer(reference)
    }

    /// Docker state for one container. Never started (no start time) is
    /// "created"; otherwise "exited", with the code if we saw it: from the
    /// exit recorder, or from `containerWait`, which still answers while the
    /// apiserver keeps the run's client.
    func describe(_ container: Container) async -> DockerContainer {
        let id = DockerContainer.id(for: container)
        // Only a stopped container is asked: waiting on one that is still
        // stopping would block until it exits. Docker has no "stopping".
        guard container.state == .stopped else {
            var item = DockerContainer(container: container, id: id, state: .running, exit: nil)
            item.health = await health?.health(for: container)
            return item
        }
        guard container.status.startedDate != nil else {
            return DockerContainer(container: container, id: id, state: .created, exit: nil)
        }
        if let exit = await exits?.exit(for: container) {
            return DockerContainer(container: container, id: id, state: .exited, exit: exit)
        }
        let exit = try? await backend.waitContainer(container.id)
        if let exit { await exits?.record(exit, for: container) }
        return DockerContainer(container: container, id: id, state: .exited, exit: exit)
    }
}
