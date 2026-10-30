import Foundation
import ContainerKit

/// Remembers how containers exit. The apiserver only reports an exit code to
/// someone waiting when the process ends; once nobody holds a wait, a stopped
/// container says "no runtime client exists". So we keep a `containerWait`
/// open on every running container and store what it returns, keyed by the
/// run (name + start time) so a restart never inherits an old code.
public actor ExitRecorder {
    struct Record: Codable, Equatable {
        let code: Int32
        let exitedAt: Date?
    }

    private let backend: DockerBackend
    private let file: URL?
    private var records: [String: Record] = [:]
    private var watching: Set<String> = []
    private var loop: Task<Void, Never>?
    /// Told about every exit a watch sees (the supervisor restarts from here).
    private var onExit: (@Sendable (String, ContainerExit) async -> Void)?

    public func setExitHandler(_ handler: @escaping @Sendable (String, ContainerExit) async -> Void) {
        onExit = handler
    }

    public init(backend: DockerBackend, file: URL? = nil) {
        self.backend = backend
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = saved
        }
    }

    /// Watch running containers every `interval` until `stop()`.
    public func start(interval: Duration = .seconds(2)) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scan()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// The recorded exit of this container's latest run, if seen.
    public func exit(for container: Container) -> ContainerExit? {
        guard let key = Self.key(container), let record = records[key] else { return nil }
        return ContainerExit(code: record.code, exitedAt: record.exitedAt)
    }

    /// Store an exit learned elsewhere (e.g. a client's own wait).
    public func record(_ exit: ContainerExit, for container: Container) {
        guard let key = Self.key(container) else { return }
        records[key] = Record(code: exit.code, exitedAt: exit.exitedAt)
        save()
    }

    /// Start a wait for each running container not yet watched; forget
    /// records of containers that no longer exist.
    func scan() async {
        guard let containers = try? await backend.listContainers(all: true) else { return }
        for container in containers where container.state.isRunning {
            guard let key = Self.key(container), !watching.contains(key) else { continue }
            watching.insert(key)
            let name = container.id
            Task { [backend] in
                let exit = try? await backend.waitContainer(name)
                await self.finished(key: key, exit: exit)
            }
        }
        let alive = Set(containers.map(\.id))
        let stale = records.keys.filter { key in !alive.contains(String(key.split(separator: "|").first ?? "")) }
        if !stale.isEmpty {
            for key in stale { records.removeValue(forKey: key) }
            save()
        }
    }

    private func finished(key: String, exit: ContainerExit?) async {
        watching.remove(key)
        guard let exit else { return }
        records[key] = Record(code: exit.code, exitedAt: exit.exitedAt)
        save()
        let name = String(key.split(separator: "|").first ?? "")
        await onExit?(name, exit)
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// name|startedDate; nil for a container that never started.
    static func key(_ container: Container) -> String? {
        guard let started = container.status.startedDate else { return nil }
        return "\(container.id)|\(started)"
    }
}
