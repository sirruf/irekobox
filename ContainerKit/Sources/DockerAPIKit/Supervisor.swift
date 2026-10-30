import Foundation
import ContainerKit
import os

/// Restart policies, as Docker applies them, for containers labelled with
/// `com.irekobox.docker.restart` (set by `docker run --restart` and by
/// compose `restart:`).
///
/// - `always`: restart after any exit, unless stopped by hand; at engine
///   start, bring it up again even if it was stopped by hand.
/// - `unless-stopped`: like `always`, but a hand stop also survives engine
///   restarts.
/// - `on-failure[:N]`: restart after a non-zero exit, at most N times.
/// - Delay doubles from 100 ms up to 1 min; it resets once a run lasted 10 s.
/// - `stop` counts as by hand; `kill` doesn't (Docker restarts after kill).
public actor Supervisor {
    public enum Policy: Equatable, Sendable {
        case always
        case unlessStopped
        case onFailure(max: Int?)

        public init?(label: String?) {
            guard let label = label?.trimmingCharacters(in: .whitespaces).lowercased(), !label.isEmpty else { return nil }
            switch label {
            case "always": self = .always
            case "unless-stopped": self = .unlessStopped
            case "on-failure": self = .onFailure(max: nil)
            default:
                guard label.hasPrefix("on-failure:"), let max = Int(label.dropFirst("on-failure:".count)), max >= 0 else {
                    return nil   // "no" and anything unknown
                }
                self = .onFailure(max: max)
            }
        }
    }

    struct State: Codable, Equatable {
        /// Containers stopped by hand: no restarts until started by hand.
        var stoppedByHand: Set<String> = []
        /// Restarts since the last start by hand (Docker's RestartCount).
        var restartCounts: [String: Int] = [:]
        /// Last seen engine state, kept across agent restarts: an agent that
        /// restarts while the engine runs must not take it for an engine start.
        var engineRunning = false
    }

    static let initialDelay: Duration = .milliseconds(100)
    static let maximumDelay: Duration = .seconds(60)
    static let stableRun: TimeInterval = 10

    private let backend: DockerBackend
    private let exits: ExitRecorder
    private let file: URL?
    private var state = State()
    private var delays: [String: Duration] = [:]
    private var pending: [String: Task<Void, Never>] = [:]
    private let log = Logger(subsystem: "com.irekobox", category: "supervisor")
    /// Where crashes of services and given-up restarts are reported.
    nonisolated(unsafe) var alerts: AlertLog?
    /// Sleep used for backoff (tests record it instead).
    private var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    func useSleep(_ sleep: @escaping @Sendable (Duration) async -> Void) {
        self.sleep = sleep
    }

    /// Wait for scheduled restarts (tests).
    func settle() async {
        while let task = pending.values.first { await task.value }
    }

    public init(backend: DockerBackend, exits: ExitRecorder, stateFile: URL?) {
        self.backend = backend
        self.exits = exits
        self.file = stateFile
        if let stateFile, let data = try? Data(contentsOf: stateFile),
           let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        }
    }

    /// Follow exits, and treat every engine start (including the one found at
    /// launch) like Docker's daemon start.
    public func start(engineCheck interval: Duration = .seconds(5)) async {
        await exits.setExitHandler { [weak self] name, exit in
            await self?.handleExit(name, exit)
        }
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.watchEngine()
                try? await Task.sleep(for: interval)
            }
        }
    }

    // MARK: - What clients tell us

    public func stoppedByHand(_ name: String) {
        cancelPending(name)
        guard state.stoppedByHand.insert(name).inserted else { return }
        save()
    }

    public func startedByHand(_ name: String) {
        cancelPending(name)
        let changed = state.stoppedByHand.remove(name) != nil || state.restartCounts[name] != nil
        state.restartCounts[name] = nil
        delays[name] = nil
        if changed { save() }
    }

    /// A removed container: a new one with the same name starts clean.
    public func forget(_ name: String) {
        cancelPending(name)
        delays[name] = nil
        let changed = state.stoppedByHand.remove(name) != nil || state.restartCounts.removeValue(forKey: name) != nil
        if changed { save() }
    }

    func isStoppedByHand(_ name: String) -> Bool { state.stoppedByHand.contains(name) }

    public func restartCount(_ name: String) -> Int {
        state.restartCounts[name] ?? 0
    }

    // MARK: - Exits

    func handleExit(_ name: String, _ exit: ContainerExit) async {
        guard let container = try? await backend.listContainers(all: true).first(where: { $0.id == name }) else { return }
        if state.stoppedByHand.contains(name) { return }
        let policy = Policy(label: container.configuration.labels[DockerLabels.restartPolicy])
        // Services only (a restart policy or a compose project): a one-off
        // `docker run` that fails is the user's own business.
        let service = policy != nil || container.configuration.labels["com.docker.compose.project"] != nil
        if service, exit.code != 0 {
            let restarting: String
            switch policy {
            case .onFailure(let max?) where restartCount(name) >= max: restarting = ""
            case .some: restarting = "; restarting"
            case nil: restarting = ""
            }
            // 137 is SIGKILL, nearly always the memory limit.
            let reason = exit.code == 137 ? ": out of memory" : ""
            await alerts?.add(.died, container: name, detail: "Exited with code \(exit.code)\(reason)\(restarting)")
        }
        guard let policy else { return }
        if case .onFailure(let max) = policy {
            guard exit.code != 0 else { return }
            if let max, restartCount(name) >= max {
                log.info("\(name, privacy: .public): on-failure limit \(max) reached")
                await alerts?.add(.gaveUp, container: name, detail: "Stopped restarting after \(max) tries")
                return
            }
        }
        // A run that lasted resets the backoff.
        let started = container.startedDate
        if let started, let ended = exit.exitedAt, ended.timeIntervalSince(started) >= Self.stableRun {
            delays[name] = nil
        }
        let delay = delays[name] ?? Self.initialDelay
        delays[name] = min(delay * 2, Self.maximumDelay)
        schedule(name, after: delay)
    }

    private func schedule(_ name: String, after delay: Duration) {
        cancelPending(name)
        let sleep = self.sleep
        pending[name] = Task { [weak self] in
            await sleep(delay)
            guard !Task.isCancelled else { return }
            await self?.restart(name)
        }
    }

    private func restart(_ name: String) async {
        pending[name] = nil
        guard !state.stoppedByHand.contains(name) else { return }
        // Engine stopped (all containers exited with it): wait for its start.
        guard (try? await backend.systemStatus())??.isRunning == true else { return }
        guard let container = try? await backend.listContainers(all: true).first(where: { $0.id == name }),
              !container.state.isRunning else { return }
        do {
            try await backend.startContainer(name)
            state.restartCounts[name, default: 0] += 1
            save()
            log.info("restarted \(name, privacy: .public) (\(self.state.restartCounts[name] ?? 0))")
            await exits.scan()      // watch the new run right away
        } catch {
            log.error("restart of \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func cancelPending(_ name: String) {
        pending.removeValue(forKey: name)?.cancel()
    }

    // MARK: - Engine start

    /// On an engine start: `always` comes back even after a hand stop (which
    /// is then forgotten), `unless-stopped` only if not stopped by hand.
    func watchEngine() async {
        // A container list over XPC answers only while the services run, and
        // costs no process; `system status` (a CLI process) only confirms when
        // it doesn't answer, so a passing XPC hiccup can't fake an engine stop
        // (and the restart-policy pass that follows an engine start).
        let running: Bool
        if (try? await backend.listContainers(all: false)) != nil {
            running = true
        } else {
            running = (try? await backend.systemStatus())??.isRunning == true
        }
        guard running != state.engineRunning else { return }
        state.engineRunning = running
        save()
        if running { await engineStarted() }
    }

    func engineStarted() async {
        guard let containers = try? await backend.listContainers(all: true) else { return }
        var changed = false
        for container in containers where !container.state.isRunning {
            guard let policy = Policy(label: container.configuration.labels[DockerLabels.restartPolicy]) else { continue }
            let name = container.id
            switch policy {
            case .always:
                if state.stoppedByHand.remove(name) != nil { changed = true }
            case .unlessStopped:
                if state.stoppedByHand.contains(name) { continue }
            case .onFailure:
                continue
            }
            do {
                try await backend.startContainer(name)
                log.info("started \(name, privacy: .public) with the engine")
            } catch {
                log.error("start of \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if changed { save() }
        await exits.scan()
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
