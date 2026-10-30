import Foundation
import ContainerKit
import os

/// Docker's embedded DNS, by /etc/hosts: on user-defined networks, containers
/// find each other by name and by their network aliases (compose service
/// names). `container` 1.6 registers only each container's hostname, on its
/// first network, and resolves no aliases — so the agent keeps every such
/// container's /etc/hosts listing its neighbours, with the address on the
/// network they share. The default network gets no names, as in Docker.
public actor HostsSync {
    struct Peer: Equatable {
        let name: String
        let address: String
        let aliases: [String]
    }

    private let backend: DockerBackend
    /// name|started → the file last written.
    private var written: [String: String] = [:]
    /// name|started → when writing last failed (retried after a while).
    private var failed: [String: Date] = [:]
    private var loop: Task<Void, Never>?
    /// Rounds asked for and done; a round covers every request made before it began.
    private var requested = 0
    private var completed = 0
    private var running: Task<Void, Never>?
    private let log = Logger(subsystem: "com.irekobox", category: "hosts")

    public init(backend: DockerBackend) {
        self.backend = backend
    }

    public func start(interval: Duration = .seconds(2)) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Bring every file up to date now (also after a start through the API,
    /// so a service doesn't wait for the next round to find its peers).
    /// Returns once a round that began after the call has finished: one
    /// already under way may have listed the containers before this caller's
    /// started, and a service that starts at once (nginx resolving its
    /// upstreams) must find its neighbours in the file.
    public func sync() async {
        requested += 1
        let target = requested
        while completed < target {
            if let running {
                await running.value
                continue
            }
            let covers = requested
            let task = Task {
                await self.round()
                self.completed = max(self.completed, covers)
                self.running = nil
            }
            running = task
            await task.value
        }
    }

    private func round() async {
        guard let containers = try? await backend.listContainers(all: false) else { return }
        let running = containers.filter { $0.state.isRunning }
        let files = Self.files(for: running.filter { !$0.isSystem }) + Self.machineFiles(for: running)
        var live: Set<String> = []
        var changed: [(key: String, container: Container, content: String)] = []
        for (container, content) in files {
            let key = Self.key(container)
            live.insert(key)
            guard written[key] != content else { continue }
            if let last = failed[key], Date().timeIntervalSince(last) < 30 { continue }
            changed.append((key, container, content))
        }
        // All at once: a start through the API waits for this, and in a
        // compose project each start changes every neighbour's file.
        let backend = backend
        let outcomes = await withTaskGroup(of: (String, String, String, Error?).self) { group in
            for file in changed {
                group.addTask {
                    do {
                        try await Self.write(file.content, into: file.container, backend: backend)
                        return (file.key, file.container.id, file.content, nil)
                    } catch {
                        return (file.key, file.container.id, file.content, error)
                    }
                }
            }
            var all: [(String, String, String, Error?)] = []
            for await outcome in group { all.append(outcome) }
            return all
        }
        for (key, name, content, error) in outcomes {
            if let error {
                failed[key] = Date()
                log.error("/etc/hosts of \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            } else {
                written[key] = content
                failed[key] = nil
            }
        }
        written = written.filter { live.contains($0.key) }
        failed = failed.filter { live.contains($0.key) }
    }

    /// Over XPC with `sh -c 'cat > /etc/hosts'` (no CLI process); an image
    /// without a shell gets the file through `container cp` as before.
    private static func write(_ content: String, into container: Container, backend: DockerBackend) async throws {
        if let run = try? await InContainer.run(["/bin/sh", "-c", "cat > /etc/hosts"], in: container,
                                                input: Data(content.utf8), backend: backend),
           run.code == 0 {
            return
        }
        try await copy(content, into: container.id, backend: backend)
    }

    private static func copy(_ content: String, into name: String, backend: DockerBackend) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "irekobox-hosts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "hosts")
        try Data(content.utf8).write(to: file)
        try await backend.copy(from: file.path, to: "\(name):/etc/hosts")
    }

    /// Machines all sit on the default network, where container gives no
    /// names: each machine's /etc/hosts lists the other machines (`name`,
    /// `name.machine`) and the containers there, so `ssh other` works.
    static func machineFiles(for running: [Container]) -> [(Container, String)] {
        var peers: [Peer] = []
        for container in running {
            guard let attachment = container.status.networks.first(where: { $0.network == "default" }),
                  let address = address(attachment.ipv4Address) else { continue }
            if let name = container.machineName {
                peers.append(Peer(name: name, address: address, aliases: ["\(name).machine"]))
            } else {
                peers.append(Peer(name: container.id, address: address, aliases: []))
            }
        }
        var result: [(Container, String)] = []
        for machine in running.filter(\.isMachine).sorted(by: { $0.id < $1.id }) {
            guard let own = machine.machineName else { continue }
            var lines = ["# Written by Irekobox: machines and containers on the default network.",
                         "127.0.0.1\tlocalhost", "::1\tlocalhost ip6-localhost ip6-loopback"]
            var taken: Set<String> = ["localhost"]
            for peer in peers.sorted(by: { ($0.name != own ? 1 : 0, $0.name) < ($1.name != own ? 1 : 0, $1.name) }) {
                let names = ([peer.name] + peer.aliases).filter { taken.insert($0).inserted }
                if !names.isEmpty { lines.append("\(peer.address)\t\(names.joined(separator: " "))") }
            }
            result.append((machine, lines.joined(separator: "\n") + "\n"))
        }
        return result
    }

    static func key(_ container: Container) -> String {
        "\(container.id)|\(container.status.startedDate ?? "")"
    }

    // MARK: - Contents

    static func isUserNetwork(_ name: String?) -> Bool {
        guard let name else { return false }
        return name != "default" && name != "bridge"
    }

    /// Aliases per network: our label, else compose's service name.
    static func aliases(_ container: Container) -> [String: [String]] {
        let labels = container.configuration.labels
        if let text = labels[DockerLabels.aliases],
           let value = try? JSONDecoder().decode([String: [String]].self, from: Data(text.utf8)) {
            return value
        }
        if let service = labels["com.docker.compose.service"] {
            var result: [String: [String]] = [:]
            for network in container.configuration.networks.map(\.network) where isUserNetwork(network) {
                result[network] = [service]
            }
            return result
        }
        return [:]
    }

    static func address(_ cidr: String?) -> String? {
        cidr?.split(separator: "/").first.map(String.init)
    }

    /// The /etc/hosts of each running container on a user-defined network.
    static func files(for running: [Container]) -> [(Container, String)] {
        // network → who is on it, with the address there.
        var members: [String: [Peer]] = [:]
        for container in running {
            let aliases = aliases(container)
            for attachment in container.status.networks where isUserNetwork(attachment.network) {
                guard let network = attachment.network, let address = address(attachment.ipv4Address) else { continue }
                members[network, default: []].append(
                    Peer(name: container.id, address: address, aliases: aliases[network] ?? []))
            }
        }
        var result: [(Container, String)] = []
        for container in running.sorted(by: { $0.id < $1.id }) {
            let networks = container.status.networks.filter { isUserNetwork($0.network) }
            guard !networks.isEmpty else { continue }
            var lines = ["# Written by Irekobox: names on this container's networks.",
                         "127.0.0.1\tlocalhost", "::1\tlocalhost ip6-localhost ip6-loopback"]
            var taken: Set<String> = ["localhost"]
            func add(_ address: String, _ names: [String]) {
                let fresh = names.filter { !$0.isEmpty && taken.insert($0).inserted }
                if !fresh.isEmpty { lines.append("\(address)\t\(fresh.joined(separator: " "))") }
            }
            let own = aliases(container)
            if let first = networks.first, let address = address(first.ipv4Address) {
                add(address, [container.id] + (own[first.network ?? ""] ?? []))
            }
            for attachment in networks {
                let network = attachment.network ?? ""
                for peer in (members[network] ?? []).sorted(by: { $0.name < $1.name }) where peer.name != container.id {
                    add(peer.address, peer.aliases + [peer.name])
                }
            }
            result.append((container, lines.joined(separator: "\n") + "\n"))
        }
        return result
    }
}
