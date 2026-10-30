import Foundation
import ContainerKit
import os

/// Docker health checks, run by the agent for containers with a
/// `com.irekobox.docker.healthcheck` label (Docker's HealthConfig as
/// JSON, written by the Docker API and by compose projects).
///
/// Docker's rules: "starting" until the first passing probe; failures during
/// the start period don't count; `retries` failures in a row → "unhealthy";
/// one pass → "healthy". A probe runs `CMD` as is or `CMD-SHELL` with
/// /bin/sh -c, exits 0 to pass, and fails when it takes longer than the
/// timeout. Probes of one container never overlap.
public actor HealthMonitor {
    public struct Config: Codable, Equatable, Sendable {
        public var Test: [String]?
        public var Interval: Int64?
        public var Timeout: Int64?
        public var Retries: Int?
        public var StartPeriod: Int64?
        public var StartInterval: Int64?

        public init(Test: [String]?, Interval: Int64? = nil, Timeout: Int64? = nil, Retries: Int? = nil,
                    StartPeriod: Int64? = nil, StartInterval: Int64? = nil) {
            self.Test = Test
            self.Interval = Interval
            self.Timeout = Timeout
            self.Retries = Retries
            self.StartPeriod = StartPeriod
            self.StartInterval = StartInterval
        }

        static func seconds(_ nanoseconds: Int64?, default value: TimeInterval) -> TimeInterval {
            guard let nanoseconds, nanoseconds > 0 else { return value }
            return TimeInterval(nanoseconds) / 1_000_000_000
        }
        var interval: TimeInterval { Self.seconds(Interval, default: 30) }
        var timeout: TimeInterval { Self.seconds(Timeout, default: 30) }
        var startPeriod: TimeInterval { Self.seconds(StartPeriod, default: 0) }
        var startInterval: TimeInterval { Self.seconds(StartInterval, default: 5) }
        var retries: Int { (Retries ?? 0) > 0 ? Retries! : 3 }

        /// The command a probe runs; nil when disabled.
        var command: [String]? {
            guard let test = Test, let kind = test.first else { return nil }
            switch kind {
            case "CMD": return test.count > 1 ? Array(test.dropFirst()) : nil
            case "CMD-SHELL": return test.count > 1 ? ["/bin/sh", "-c", test[1]] : nil
            case "NONE": return nil
            default: return test     // a bare list, as some clients send
            }
        }
    }

    public enum Status: String, Codable, Sendable {
        case starting, healthy, unhealthy
    }

    public struct Probe: Codable, Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let exitCode: Int
        public let output: String
    }

    public struct Health: Equatable, Sendable {
        public var status: Status = .starting
        public var failingStreak = 0
        public var log: [Probe] = []
    }

    /// One probe: the command's exit code and output.
    public typealias Runner = @Sendable (_ container: String, _ command: [String], _ timeout: TimeInterval) async -> (Int, String)

    struct Tracked {
        var health = Health()
        let started: Date
        var nextProbe: Date
        var probing = false
    }

    private let backend: DockerBackend
    private var runner: Runner
    private var tracked: [String: Tracked] = [:]          // name|started → state
    private var loop: Task<Void, Never>?
    /// The loop's current sleep; a finished probe cuts it short, so the next
    /// one is scheduled from its real end.
    private var nap: Task<Void, Never>?
    private var onChange: (@Sendable (Container, Health, Status?) async -> Void)?
    private let log = Logger(subsystem: "com.irekobox", category: "health")

    public init(backend: DockerBackend, runner: Runner? = nil) {
        self.backend = backend
        self.runner = runner ?? Self.execRunner(backend)
    }

    /// Told about every status change (container, new health, old status).
    public func setChangeHandler(_ handler: @escaping @Sendable (Container, Health, Status?) async -> Void) {
        onChange = handler
    }

    /// Look for containers every `tick`, and wake for each probe when it is
    /// due rather than on the next tick: `compose up --wait` waits on the
    /// first probe, which Docker runs one interval after the start.
    public func start(tick: Duration = .seconds(1)) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = await self?.roundThenWait(now: Date(), tick: tick) else { return }
                await self?.sleep(for: wait)
            }
        }
    }

    /// A round, then how long to sleep: a tick, or less when a probe falls
    /// due sooner.
    func roundThenWait(now: Date, tick: Duration) async -> Duration {
        await round(now: now)
        guard let due = tracked.values.filter({ !$0.probing }).map(\.nextProbe).min() else { return tick }
        let seconds = max(0.02, due.timeIntervalSince(Date()))
        return min(tick, .milliseconds(Int(seconds * 1000)))
    }

    private func sleep(for wait: Duration) async {
        let task = Task<Void, Never> { _ = try? await Task.sleep(for: wait) }
        nap = task
        await task.value
        if nap == task { nap = nil }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        nap?.cancel()
    }

    /// The current health of this run of the container, if it has a check.
    /// A running container with a check the monitor hasn't reached yet is
    /// "starting": with no Health at all, `compose up --wait` would decide it
    /// has no check and fail.
    public func health(for container: Container) -> Health? {
        if let tracked = tracked[Self.key(container)] { return tracked.health }
        return container.state.isRunning && Self.config(container) != nil ? Health() : nil
    }

    /// name → status, for every running container with a check.
    public func statuses() -> [String: Status] {
        var result: [String: Status] = [:]
        for (key, state) in tracked { result[String(key.split(separator: "|").first ?? "")] = state.health.status }
        return result
    }

    static func key(_ container: Container) -> String {
        "\(container.id)|\(container.status.startedDate ?? "")"
    }

    static func config(_ container: Container) -> Config? {
        guard let text = container.configuration.labels[DockerLabels.healthcheck],
              let config = try? JSONDecoder().decode(Config.self, from: Data(text.utf8)),
              config.command != nil else { return nil }
        return config
    }

    func round(now: Date) async {
        guard let containers = try? await backend.listContainers(all: false) else { return }
        var live: Set<String> = []
        for container in containers where container.state.isRunning {
            guard let config = Self.config(container) else { continue }
            let key = Self.key(container)
            live.insert(key)
            if tracked[key] == nil {
                let started = container.status.startedDate.flatMap(DockerTime.parse) ?? now
                tracked[key] = Tracked(started: started, nextProbe: started.addingTimeInterval(min(config.startInterval, config.interval)))
            }
            guard var state = tracked[key], !state.probing, now >= state.nextProbe else { continue }
            state.probing = true
            tracked[key] = state
            let runner = self.runner
            Task {
                let begun = Date()
                let (code, output) = await runner(container.id, config.command!, config.timeout)
                await self.finished(container, key: key, config: config,
                                    probe: Probe(start: begun, end: Date(), exitCode: code, output: output))
            }
        }
        tracked = tracked.filter { live.contains($0.key) }
    }

    func finished(_ container: Container, key: String, config: Config, probe: Probe) async {
        guard var state = tracked[key] else { return }    // stopped meanwhile
        let before = state.health.status
        Self.apply(probe, to: &state.health, config: config, started: state.started)
        let inStart = probe.end.timeIntervalSince(state.started) < config.startPeriod
        let wait = (inStart && state.health.status == .starting) ? config.startInterval : config.interval
        state.nextProbe = probe.end.addingTimeInterval(wait)
        state.probing = false
        tracked[key] = state
        nap?.cancel()
        if state.health.status != before {
            log.info("\(container.id, privacy: .public): \(state.health.status.rawValue, privacy: .public)")
            await onChange?(container, state.health, before)
        }
    }

    /// Docker's state machine for one probe result.
    static func apply(_ probe: Probe, to health: inout Health, config: Config, started: Date) {
        health.log.append(probe)
        if health.log.count > 5 { health.log.removeFirst(health.log.count - 5) }
        if probe.exitCode == 0 {
            health.status = .healthy
            health.failingStreak = 0
            return
        }
        // Failures in the start period don't count until a probe has passed.
        let inStart = probe.end.timeIntervalSince(started) < config.startPeriod
        if inStart && health.status == .starting { return }
        health.failingStreak += 1
        if health.failingStreak >= config.retries { health.status = .unhealthy }
    }

    /// Run the probe with `container exec`; exit 0 passes. A timeout fails
    /// it (the command itself is left to finish; probes don't overlap).
    static func execRunner(_ backend: DockerBackend) -> Runner {
        { container, command, timeout in
            await withCheckedContinuation { (continuation: CheckedContinuation<(Int, String), Never>) in
                let once = Once()
                Task {
                    let result: (Int, String)
                    do {
                        let data = try await backend.execute(container, command: command)
                        result = (0, String(decoding: data.prefix(4096), as: UTF8.self))
                    } catch EngineError.commandFailed(let code, let message) {
                        result = (Int(code), String(message.prefix(4096)))
                    } catch {
                        result = (-1, error.localizedDescription)
                    }
                    if once.claim() { continuation.resume(returning: result) }
                }
                Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    if once.claim() {
                        continuation.resume(returning: (-1, "Health check exceeded timeout (\(Int(timeout))s)"))
                    }
                }
            }
        }
    }

    /// The first caller wins.
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func claim() -> Bool {
            lock.withLock {
                if taken { return false }
                taken = true
                return true
            }
        }
    }
}
