import Foundation
import CryptoKit
import Observation
import ContainerKit
import ComposeKit
import StackKit

/// The Compose screen's state: projects added here (run by us from their
/// compose file) and projects found on containers `docker compose` started.
@MainActor
@Observable
final class ComposeViewModel {
    private let engine: any ContainerEngine
    private let runner: ComposeRunner
    /// Tells the agent a container was stopped or started by hand.
    var onHandAction: (_ stopped: Bool, _ ids: [String]) -> Void = { _, _ in }

    private(set) var projects: [ComposeProject] = []
    private(set) var loaded = false
    /// Projects added here whose compose file now asks for something else
    /// than what runs: how many services would change, and when the file was saved.
    private(set) var fileChanges: [String: FileChange] = [:]

    struct FileChange: Equatable {
        let services: Int
        let saved: Date?
    }
    var busy: Set<String> = []
    var error: String?

    init(engine: any ContainerEngine, runner: ComposeRunner) {
        self.engine = engine
        self.runner = runner
    }

    func project(named name: String) -> ComposeProject? { projects.first { $0.name == name } }

    func reload() async {
        let entries = StackStore.load()
        let containers: [Container]
        do {
            containers = try await engine.listContainers(all: true)
        } catch {
            self.error = error.localizedDescription
            containers = []
        }
        projects = ComposeProject.all(entries: entries, containers: containers)
        fileChanges = Dictionary(uniqueKeysWithValues: projects.compactMap { project in
            fileChange(of: project).map { (project.name, $0) }
        })
        loaded = true
    }

    /// What applying the saved file would change; `nil` when it runs as
    /// written, isn't running here, or the file can't be read.
    private func fileChange(of project: ComposeProject) -> FileChange? {
        guard let entry = project.entry, !project.containers.isEmpty,
              let (plan, _) = try? plan(for: entry) else { return nil }
        let count = Self.changes(plan, existing: project.containers).filter {
            if case .keep = $0 { return false } else { return true }
        }.count
        guard count > 0 else { return nil }
        let saved = (try? FileManager.default.attributesOfItem(atPath: entry.composePath))?[.modificationDate] as? Date
        return FileChange(services: count, saved: saved)
    }

    /// Bring the project in line with its compose file as saved.
    func applySavedFile(_ project: ComposeProject) async {
        guard let path = project.composePath else { return }
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            await apply(project, text: text, to: path, dockerSocket: nil)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Adding

    static let composeFileNames = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]

    /// The compose file for a dropped or chosen folder or file.
    static func composeFile(at url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else { return url }
        return composeFileNames.map { url.appending(path: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Docker Compose's default name: the file's `name:`, else its folder.
    static func projectName(for file: URL) -> String {
        if let parsed = try? ComposeParser().parse(contentsOf: file), let name = parsed.file.name, !name.isEmpty {
            return sanitize(name)
        }
        return sanitize(file.deletingLastPathComponent().lastPathComponent)
    }

    /// Add a folder or compose file; returns the project's name.
    @discardableResult
    func add(_ url: URL) -> String? {
        guard let file = Self.composeFile(at: url) else {
            error = String(localized: "No compose.yaml in \(url.lastPathComponent).")
            return nil
        }
        var list = StackStore.load()
        if let existing = list.first(where: { $0.composePath == file.path }) { return existing.name }
        var name = Self.projectName(for: file)
        if name.isEmpty { name = "project" }
        let taken = Set(list.map(\.name))
        if taken.contains(name) {
            name = (2...).lazy.map { "\(name)-\($0)" }.first { !taken.contains($0) }!
        }
        list.append(StackEntry(name: name, composePath: file.path))
        do {
            try StackStore.save(list)
            error = nil
        } catch {
            self.error = String(localized: "Couldn't save projects: \(error.localizedDescription)")
            return nil
        }
        Task { await reload() }
        return name
    }

    // MARK: - Reading the compose file

    func file(of project: ComposeProject) -> ComposeFile? {
        guard let path = project.composePath else { return nil }
        return try? ComposeParser().parse(contentsOf: URL(fileURLWithPath: path)).file
    }

    func services(of project: ComposeProject) -> [ComposeService] {
        project.services(file: file(of: project))
    }

    /// Host folders mounted into services (`service: path`).
    func bindMounts(of project: ComposeProject) -> [String] {
        guard let file = file(of: project) else { return [] }
        return file.services.sorted { $0.key < $1.key }.flatMap { name, service in
            (service.volumes ?? []).filter { $0.kind == .bind }.map { "\(name): \($0.source ?? $0.target)" }
        }
    }

    /// The local DNS domain (names like `web.shop.test`), read before a run.
    private var localDomain: String?
    /// Names already held by other containers (the runtime refuses a second).
    private var takenNames: Set<String> = []

    /// What we'd run for a project added here (from `text` instead of the
    /// file when given). Each run carries a hash of its settings.
    func plan(for entry: StackEntry, text: String? = nil) throws -> (plan: ComposePlan, directory: URL) {
        let url = URL(fileURLWithPath: entry.composePath)
        let parsed = try text.map { try ComposeParser().parse($0) } ?? ComposeParser().parse(contentsOf: url)
        var plan = try ComposePlanner().plan(parsed, projectName: entry.name,
                                             extraRunLabels: ComposeProject.runLabels(for: entry),
                                             localDomain: localDomain)
        plan = Self.stamped(plan)
        if !takenNames.isEmpty { plan = Self.dropping(takenNames, from: plan) }
        return (plan, url.deletingLastPathComponent())
    }

    // MARK: - Changes to a running project

    /// The label holding a hash of what a container was run with, so an
    /// edit recreates only the services whose settings changed.
    static let configHashLabel = "com.irekobox.compose.config-hash"

    static func configHash(_ arguments: [String]) -> String {
        SHA256.hash(data: Data(arguments.joined(separator: "\u{0}").utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// The plan with each run's settings hash as a label.
    static func stamped(_ plan: ComposePlan) -> ComposePlan {
        let steps = plan.steps.map { step -> PlanStep in
            guard step.kind == .run, let first = step.arguments.first else { return step }
            let hash = configHash(step.arguments)
            return PlanStep(kind: step.kind, service: step.service, containerName: step.containerName,
                            arguments: [first, "--label", "\(configHashLabel)=\(hash)"] + step.arguments.dropFirst())
        }
        return ComposePlan(projectName: plan.projectName, steps: steps, warnings: plan.warnings)
    }

    enum Change: Hashable, Identifiable {
        case add(service: String)
        /// Its settings changed (or weren't recorded): deleted and run again.
        case recreate(service: String, container: String)
        case keep(service: String)
        /// No longer in the file.
        case remove(container: String)

        var id: String {
            switch self {
            case .add(let service): return "add:\(service)"
            case .recreate(_, let container): return "recreate:\(container)"
            case .keep(let service): return "keep:\(service)"
            case .remove(let container): return "remove:\(container)"
            }
        }
    }

    /// What applying `plan` does to the project's `existing` containers.
    static func changes(_ plan: ComposePlan, existing: [Container]) -> [Change] {
        var result: [Change] = []
        var matched: Set<String> = []
        for step in plan.steps where step.kind == .run {
            guard let name = step.containerName else { continue }
            let service = step.service ?? name
            guard let container = existing.first(where: { $0.id == name }) else {
                result.append(.add(service: service))
                continue
            }
            matched.insert(name)
            let wanted = step.arguments.firstIndex(of: "\(configHashLabel)=\(container.configuration.labels[configHashLabel] ?? "")")
            result.append(wanted == nil ? .recreate(service: service, container: name) : .keep(service: service))
        }
        for container in existing where !matched.contains(container.id) {
            result.append(.remove(container: container.id))
        }
        return result
    }

    /// Check an edit: the plan and what applying it would change.
    func preview(_ project: ComposeProject, text: String) -> Result<(plan: ComposePlan, changes: [Change]), Error> {
        Result {
            if let entry = project.entry {
                let (plan, _) = try plan(for: entry, text: text)
                return (plan, Self.changes(plan, existing: project.containers))
            }
            let parsed = try ComposeParser().parse(text)
            let plan = try ComposePlanner().plan(parsed, projectName: project.name)
            return (plan, [])
        }
    }

    /// Save `text` to `path` and bring the project in line with it: for a
    /// project added here, recreate only what changed; for one `docker
    /// compose` started, run `docker compose up -d` against our Docker API.
    func apply(_ project: ComposeProject, text: String, to path: String, dockerSocket: String?) async {
        await perform(project) {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            guard let entry = project.entry else {
                try await composeUp(project, socket: dockerSocket)
                return
            }
            try await prepareRun(excluding: project.name)
            let (plan, directory) = try plan(for: entry)
            let changes = Self.changes(plan, existing: project.containers)
            var stale: [String] = []
            var services: Set<String> = []
            for change in changes {
                switch change {
                case .add(let service): services.insert(service)
                case .recreate(let service, let container): services.insert(service); stale.append(container)
                case .remove(let container): stale.append(container)
                case .keep: break
                }
            }
            onHandAction(true, stale)
            for id in stale {
                if project.containers.first(where: { $0.id == id })?.state.isRunning == true {
                    try await engine.stopContainer(id)
                }
                try await engine.deleteContainer(id, force: true)
            }
            let steps = plan.steps.filter { step in
                switch step.kind {
                case .network, .volume: return true
                case .build, .run: return services.contains(step.service ?? "")
                }
            }
            if steps.contains(where: { $0.kind == .run }) {
                try Self.check(await runner.up(ComposePlan(projectName: plan.projectName, steps: steps,
                                                           warnings: plan.warnings),
                                               workingDirectory: directory))
            }
        }
    }

    struct ComposeUpError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `docker compose up -d` for a project it started, through our socket.
    private func composeUp(_ project: ComposeProject, socket: String?) async throws {
        guard let socket else {
            throw ComposeUpError(message: String(localized: "Saved. To apply, turn on the Docker API in Settings › Engine, then run docker compose up -d."))
        }
        guard let docker = DockerEnvironment.dockerPath() else {
            throw ComposeUpError(message: String(localized: "Saved. The docker CLI isn't installed; run docker compose up -d in the project folder."))
        }
        var arguments = ["compose", "--project-name", project.name]
        for file in project.configFiles { arguments += ["--file", file] }
        arguments += ["up", "--detach", "--remove-orphans"]
        try await ProcessRunner.run(executable: docker, arguments, environment: ["DOCKER_HOST": "unix://\(socket)"],
                                    workingDirectory: project.directory.map { URL(fileURLWithPath: $0) })
    }

    /// The plan without network aliases another container already holds.
    static func dropping(_ names: Set<String>, from plan: ComposePlan) -> ComposePlan {
        let steps = plan.steps.map { step in
            PlanStep(kind: step.kind, service: step.service, containerName: step.containerName,
                     arguments: step.arguments.map { argument in
                         guard let range = argument.range(of: ",alias="),
                               names.contains(String(argument[range.upperBound...])) else { return argument }
                         return String(argument[..<range.lowerBound])
                     })
        }
        return ComposePlan(projectName: plan.projectName, steps: steps, warnings: plan.warnings)
    }

    /// Only the steps that create what doesn't exist yet: existing
    /// containers are started instead of run again.
    static func missing(from plan: ComposePlan, existing: Set<String>) -> ComposePlan {
        let steps = plan.steps.filter { step in
            switch step.kind {
            case .run: return !existing.contains(step.containerName ?? "")
            case .build: return !plan.steps.contains { $0.kind == .run && $0.service == step.service
                && existing.contains($0.containerName ?? "") }
            case .network, .volume: return true
            }
        }
        return ComposePlan(projectName: plan.projectName, steps: steps, warnings: plan.warnings)
    }

    // MARK: - Actions

    /// Start what exists; for a project added here, also create what's missing.
    func start(_ project: ComposeProject) async {
        await perform(project) {
            let stopped = project.containers.filter { !$0.state.isRunning }.map(\.id)
            if !stopped.isEmpty {
                onHandAction(false, stopped)
                for id in stopped { try await engine.startContainer(id) }
            }
            if let entry = project.entry {
                try await prepareRun(excluding: project.name)
                let (plan, directory) = try plan(for: entry)
                let missing = Self.missing(from: plan, existing: Set(project.containers.map(\.id)))
                if missing.steps.contains(where: { $0.kind == .run }) {
                    try Self.check(await runner.up(missing, workingDirectory: directory))
                }
            }
        }
    }

    func stop(_ project: ComposeProject) async {
        await perform(project) {
            let running = project.containers.filter { $0.state.isRunning }.map(\.id)
            onHandAction(true, running)
            for id in running { try await engine.stopContainer(id) }
        }
    }

    func restart(_ project: ComposeProject) async {
        await stop(project)
        await reload()
        if let fresh = self.project(named: project.name) { await start(fresh) }
    }

    /// Remove the containers and run the compose file again (after editing it).
    func recreate(_ project: ComposeProject) async {
        guard let entry = project.entry else { return }
        await perform(project) {
            try await prepareRun(excluding: project.name)
            let (plan, directory) = try plan(for: entry)
            onHandAction(true, project.containers.map(\.id))
            await runner.down(plan, workingDirectory: directory)
            try await removeLeftovers(project, keeping: [])
            await reload()
            try await prepareRun(excluding: project.name)
            let (fresh, _) = try self.plan(for: entry)
            try Self.check(await runner.up(fresh, workingDirectory: directory))
        }
    }

    /// Stop and delete the project's containers; volumes stay.
    func removeContainers(_ project: ComposeProject) async {
        await perform(project) {
            onHandAction(true, project.containers.map(\.id))
            if let entry = project.entry, let (plan, directory) = try? plan(for: entry) {
                await runner.down(plan, workingDirectory: directory)
            }
            try await removeLeftovers(project, keeping: [])
        }
    }

    /// Remove the containers and forget a project added here.
    func remove(_ project: ComposeProject) async {
        await removeContainers(project)
        var list = StackStore.load()
        list.removeAll { $0.name == project.name }
        do { try StackStore.save(list) } catch { self.error = String(localized: "Couldn't save projects: \(error.localizedDescription)") }
        await reload()
    }

    // MARK: - Internals

    private func perform(_ project: ComposeProject, _ action: () async throws -> Void) async {
        guard !busy.contains(project.name) else { return }
        busy.insert(project.name)
        defer { busy.remove(project.name) }
        do {
            try await action()
            error = nil
        } catch {
            self.error = "\(project.name): \(error.localizedDescription)"
        }
        await reload()
    }

    /// Containers of the project still there after a teardown (any name).
    private func removeLeftovers(_ project: ComposeProject, keeping: Set<String>) async throws {
        let all = try await engine.listContainers(all: true)
        for container in all where ContainerList.project(of: container) == project.name && !keeping.contains(container.id) {
            if container.state.isRunning { try await engine.stopContainer(container.id) }
            try await engine.deleteContainer(container.id, force: true)
        }
    }

    private func prepareRun(excluding project: String) async throws {
        localDomain = (try? await engine.systemProperties()).flatMap { LocalDomain.parse(properties: $0) }
        let others = try await engine.listContainers(all: true).filter { ContainerList.project(of: $0) != project }
        takenNames = Set(others.flatMap { $0.configuration.networks.flatMap { $0.options?.aliases ?? [] } })
    }

    struct StepFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The first failed step as an error.
    static func check(_ outcomes: [StepOutcome]) throws {
        for outcome in outcomes {
            if case .failed(let message) = outcome.status {
                let what = outcome.step.service.map { "\($0): " } ?? ""
                throw StepFailure(message: what + message)
            }
        }
    }

    static func sanitize(_ name: String) -> String {
        String(name.lowercased().map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "-" })
    }
}
