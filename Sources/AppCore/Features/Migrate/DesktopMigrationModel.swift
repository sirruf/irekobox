import Foundation
import Observation
import EngineCore
import MigrationKit

/// "Move from Docker Desktop": read what Docker Desktop has, show what moves
/// as is, with changes, or not at all, then move the chosen items through
/// Irekobox's Docker API. Progress is saved, so it can continue.
@MainActor
@Observable
final class DesktopMigrationModel {
    enum Phase: Equatable {
        case checking
        /// Something to fix first.
        case blocked(Blocker)
        case scanning
        case ready
        case moving
        case finished
    }

    enum Blocker: Equatable {
        case noDocker
        case desktopNotRunning
        case socketOff
        case failed(String)
    }

    private(set) var phase: Phase = .checking
    private(set) var items: [DesktopMigration.Item] = []
    private(set) var sourceVersion = ""
    private(set) var statuses: [String: DesktopMigrationRunner.Status] = [:]
    var selected: Set<String> = []
    var startRunning = true
    var stopSource = true

    private var runner: DesktopMigrationRunner?
    private var task: Task<Void, Never>?
    private var destination: String?
    private let docker = DockerEnvironment.dockerPath()
    private let source = DesktopMigration.defaultSourceSocket

    static var progressFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Irekobox/desktop-migration.json")
    }

    // MARK: - Groups

    static let order: [DesktopMigration.Kind] = [.container, .image, .volume, .network, .registry]

    func items(of kind: DesktopMigration.Kind) -> [DesktopMigration.Item] {
        items.filter { $0.kind == kind }
    }

    /// The chosen items plus what they need (moved along with them).
    var plannedIDs: Set<String> {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var result = selected
        var queue = Array(selected)
        while let id = queue.popLast() {
            for need in byID[id]?.needs ?? [] where result.insert(need).inserted { queue.append(need) }
        }
        return result.filter { byID[$0]?.movable == true }
    }

    var plannedSize: Int64 {
        let planned = plannedIDs
        return items.filter { planned.contains($0.id) }.compactMap(\.size).reduce(0, +)
    }

    var counts: (moves: Int, changes: Int, blocked: Int) {
        let movable = items.filter { $0.kind != .registry }
        return (movable.filter { $0.movable && $0.problems.isEmpty }.count,
                movable.filter { $0.movable && !$0.problems.isEmpty }.count,
                movable.filter { !$0.movable }.count)
    }

    var doneCount: Int { statuses.values.filter { $0 == .done }.count }
    var hasSavedProgress: Bool { !statuses.isEmpty }

    // MARK: - Steps

    func check(app: AppState) async {
        phase = .checking
        guard docker != nil else { phase = .blocked(.noDocker); return }
        guard let ping = try? await UnixHTTP(socketPath: source).get("/_ping", timeout: 3), ping.ok else {
            phase = .blocked(.desktopNotRunning)
            return
        }
        // Just turned on (or the app just launched): give the agent a moment.
        var status = await app.dockerSocketStatus()
        for _ in 0..<10 where app.dockerSocketEnabled && status?.listening != true {
            try? await Task.sleep(for: .milliseconds(500))
            status = await app.dockerSocketStatus()
        }
        guard let status, status.listening else {
            phase = .blocked(.socketOff)
            return
        }
        destination = status.socketPath
        await scan()
    }

    func scan() async {
        guard let docker, let destination else { return }
        phase = .scanning
        do {
            let config = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".docker/config.json")
            let inventory = try await DesktopMigration.scan(source: UnixHTTP(socketPath: source), dockerConfig: config)
            items = inventory.items
            sourceVersion = inventory.sourceVersion
            let runner = DesktopMigrationRunner(source: source, destination: destination, docker: docker,
                                                progressFile: Self.progressFile)
            self.runner = runner
            statuses = await runner.statuses()
            if selected.isEmpty {
                // What runs in Docker Desktop, and what it needs.
                selected = Set(items.filter { $0.kind == .container && $0.movable }.map(\.id))
            }
            phase = .ready
        } catch {
            phase = .blocked(.failed(error.localizedDescription))
        }
    }

    func toggle(_ item: DesktopMigration.Item) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    func move() {
        guard let runner else { return }
        let chosen = items.filter { selected.contains($0.id) }
        let all = items
        let options = DesktopMigrationRunner.Options(startRunning: startRunning, stopSource: stopSource)
        phase = .moving
        task = Task { [weak self] in
            await runner.observe { [weak self] id, status in
                Task { @MainActor in self?.statuses[id] = status }
            }
            await runner.run(chosen, all: all, options: options)
            let final = await runner.statuses()
            self?.statuses = final
            self?.phase = .finished
        }
    }

    func cancel() {
        task?.cancel()
    }

    func startOver() async {
        await runner?.reset()
        statuses = [:]
        phase = .ready
    }
}
