import Foundation
import ContainerKit

/// The single source of truth for engine state.
///
/// - **Interest-driven polling:** consumers declare which resources they show
///   (``addInterest(_:)``); only those are polled, each on its own interval.
///   Service status is always polled. In the background intervals stretch.
/// - **Single-flight with freshness:** at most one fetch per resource is in
///   flight. ``refresh(_:)`` returns once a fetch that *started after the call*
///   has completed, so data requested after a mutation is never older than the
///   mutation, and results are applied in order (no stale overwrite).
/// - **Last good data:** a failed fetch keeps the previous value and records the
///   error (``Loadable/isStale``).
/// - **Events:** each applied change is diffed into ``EngineEvent``s and
///   broadcast with the new snapshot to every ``updates()`` subscriber. A
///   fetch that returns what the store already has is not broadcast (only
///   `updatedAt` moves), so an idle engine costs subscribers nothing.
public actor EngineStore {
    public struct Intervals: Sendable {
        public var system: Duration
        public var containers: Duration
        /// Images, volumes, networks, disk usage.
        public var others: Duration
        /// Interval multiplier while the app is in the background.
        public var backgroundFactor: Int

        public init(system: Duration = .seconds(5), containers: Duration = .seconds(2),
                    others: Duration = .seconds(10), backgroundFactor: Int = 5) {
            self.system = system
            self.containers = containers
            self.others = others
            self.backgroundFactor = backgroundFactor
        }

        func interval(for resource: EngineResource, background: Bool) -> Duration {
            let base: Duration
            switch resource {
            case .system: base = system
            case .containers: base = containers
            case .images, .volumes, .networks, .diskUsage: base = others
            }
            return background ? base * backgroundFactor : base
        }
    }

    public private(set) var snapshot = EngineSnapshot()

    private var engine: any ContainerEngine
    /// Bumped by ``replaceEngine(_:)``; results from an older engine are dropped.
    private var engineGeneration = 0
    private var intervals: Intervals
    private var background = false

    private var subscribers: [UUID: AsyncStream<EngineUpdate>.Continuation] = [:]
    private var interest: [UUID: Set<EngineResource>] = [:]

    // Single-flight bookkeeping, per resource.
    private var requested: [EngineResource: Int] = [:]
    private var completed: [EngineResource: Int] = [:]
    private var inFlight: [EngineResource: Task<Void, Never>] = [:]
    private var lastFetch: [EngineResource: ContinuousClock.Instant] = [:]

    private var poller: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?

    public init(engine: any ContainerEngine, intervals: Intervals = Intervals()) {
        self.engine = engine
        self.intervals = intervals
    }

    // MARK: - Subscriptions

    /// Snapshots and events, starting with the current snapshot.
    public func updates() -> AsyncStream<EngineUpdate> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<EngineUpdate>.makeStream(bufferingPolicy: .bufferingNewest(16))
        continuation.yield(EngineUpdate(snapshot: snapshot, events: []))
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    /// Declare interest in `resources`; they are fetched now and then polled
    /// until ``removeInterest(_:)``.
    @discardableResult
    public func addInterest(_ resources: Set<EngineResource>) -> UUID {
        let id = UUID()
        interest[id] = resources
        for resource in resources where lastFetch[resource] == nil {
            fetchTask(resource)
        }
        wakePoller()
        return id
    }

    public func removeInterest(_ id: UUID) {
        interest[id] = nil
    }

    /// Resources currently polled: everything someone is interested in, plus
    /// service status.
    public var polledResources: Set<EngineResource> {
        interest.values.reduce(into: [.system]) { $0.formUnion($1) }
    }

    // MARK: - Configuration

    public var isBackground: Bool { background }

    public func setBackground(_ isBackground: Bool) {
        guard background != isBackground else { return }
        background = isBackground
        wakePoller()
    }

    public func setIntervals(_ intervals: Intervals) {
        self.intervals = intervals
        wakePoller()
    }

    /// Switch to a new engine (e.g. the binary path changed); state is reset.
    public func replaceEngine(_ engine: any ContainerEngine) {
        self.engine = engine
        engineGeneration += 1
        snapshot = EngineSnapshot()
        lastFetch = [:]
        publish([])
        for resource in polledResources {
            fetchTask(resource)
        }
    }

    // MARK: - Refresh

    /// Fetch `resources` concurrently; returns when each has data from a fetch
    /// that started after this call.
    public func refresh(_ resources: Set<EngineResource>) async {
        await withTaskGroup(of: Void.self) { group in
            for resource in resources {
                group.addTask { await self.refresh(resource) }
            }
        }
    }

    public func refresh(_ resource: EngineResource) async {
        requested[resource, default: 0] += 1
        let target = requested[resource]!
        while completed[resource, default: 0] < target {
            await fetchTask(resource).value
        }
    }

    /// The fetch of `resource` in flight, started now if there is none.
    @discardableResult
    private func fetchTask(_ resource: EngineResource) -> Task<Void, Never> {
        if let running = inFlight[resource] { return running }
        // This fetch serves every request made before it starts.
        let covers = requested[resource, default: 0]
        let task = Task {
            await self.fetch(resource)
            self.completed[resource] = max(self.completed[resource, default: 0], covers)
            self.inFlight[resource] = nil
            // The poller left this resource out of its deadline while the
            // fetch ran; let it schedule the next one.
            self.wakePoller()
        }
        inFlight[resource] = task
        return task
    }

    // MARK: - Polling

    public func startPolling() {
        guard poller == nil else { return }
        poller = Task { await pollLoop() }
    }

    public func stopPolling() {
        poller?.cancel()
        poller = nil
        sleeper?.cancel()
    }

    private func pollLoop() async {
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let now = clock.now
            let resources = polledResources
            for resource in resources where isDue(resource, at: now) {
                fetchTask(resource)
            }
            // A fetch in flight has no deadline: it wakes the poller when it
            // completes. Counting it would put the deadline in the past and
            // spin the loop for as long as the fetch runs.
            let next = resources
                .filter { inFlight[$0] == nil }
                .map { (lastFetch[$0] ?? now) + intervals.interval(for: $0, background: background) }
                .min() ?? now + .seconds(1)
            let sleeper = Task { _ = try? await Task.sleep(until: max(next, now + .milliseconds(10)), clock: clock) }
            self.sleeper = sleeper
            await sleeper.value
        }
    }

    private func isDue(_ resource: EngineResource, at now: ContinuousClock.Instant) -> Bool {
        guard inFlight[resource] == nil else { return false }
        guard let last = lastFetch[resource] else { return true }
        return now - last >= intervals.interval(for: resource, background: background)
    }

    private func wakePoller() {
        sleeper?.cancel()
    }

    // MARK: - Fetching

    private func fetch(_ resource: EngineResource) async {
        lastFetch[resource] = ContinuousClock.now
        let engine = self.engine
        let generation = engineGeneration

        if resource == .system {
            await fetchSystem(engine, generation)
            return
        }
        // Everything else needs running services.
        guard snapshot.service.isRunning else { return }

        switch resource {
        case .system:
            break
        case .containers:
            let result = await Self.capture { try await engine.listContainers(all: true) }
            guard generation == engineGeneration else { return }
            let events = result.value.map { EventDiff.containers(old: snapshot.containers.value, new: $0) } ?? []
            if apply(result, to: \.containers) { publish(events) }
        case .images:
            let result = await Self.capture { try await engine.listImages() }
            guard generation == engineGeneration else { return }
            let events = result.value.map {
                EventDiff.names(old: snapshot.images.value?.map(\.reference), new: $0.map(\.reference),
                                added: { .imageAdded(reference: $0) }, removed: { .imageRemoved(reference: $0) })
            } ?? []
            if apply(result, to: \.images) { publish(events) }
        case .volumes:
            let result = await Self.capture { try await engine.listVolumes() }
            guard generation == engineGeneration else { return }
            let events = result.value.map {
                EventDiff.names(old: snapshot.volumes.value?.map(\.name), new: $0.map(\.name),
                                added: { .volumeAdded(name: $0) }, removed: { .volumeRemoved(name: $0) })
            } ?? []
            if apply(result, to: \.volumes) { publish(events) }
        case .networks:
            let result = await Self.capture { try await engine.listNetworks() }
            guard generation == engineGeneration else { return }
            let events = result.value.map {
                EventDiff.names(old: snapshot.networks.value?.map(\.name), new: $0.map(\.name),
                                added: { .networkAdded(name: $0) }, removed: { .networkRemoved(name: $0) })
            } ?? []
            if apply(result, to: \.networks) { publish(events) }
        case .diskUsage:
            let result = await Self.capture { try await engine.diskUsage() }
            guard generation == engineGeneration else { return }
            if apply(result, to: \.diskUsage) { publish([]) }
        }
    }

    private func fetchSystem(_ engine: any ContainerEngine, _ generation: Int) async {
        let status = await Self.capture { try await engine.systemStatus() }
        let builder: BuilderStatus?
        if case .success(let status?) = status, status.isRunning {
            builder = try? await engine.builderStatus()
        } else {
            builder = nil
        }
        guard generation == engineGeneration else { return }

        let was = snapshot.service
        switch status {
        case .success(let status?) where status.isRunning:
            snapshot.service = .running(status)
        case .success:
            snapshot.service = .stopped
        case .failure(let error):
            snapshot.service = .failed(error)
        }
        let builderChanged = snapshot.builder != builder
        snapshot.builder = builder

        var events: [EngineEvent] = []
        let isRunning = snapshot.service.isRunning
        if was != .unknown && !was.isRunning && isRunning { events.append(.servicesStarted) }
        if was.isRunning && snapshot.service == .stopped { events.append(.servicesStopped) }
        if snapshot.service == .stopped {
            clearServiceData()
        }
        if snapshot.service != was || builderChanged { publish(events) }

        // Fresh services: load what consumers are waiting for.
        if !was.isRunning && isRunning {
            for resource in polledResources where resource != .system {
                fetchTask(resource)
            }
        }
    }

    private func clearServiceData() {
        snapshot.containers = Loadable()
        snapshot.images = Loadable()
        snapshot.volumes = Loadable()
        snapshot.networks = Loadable()
        snapshot.diskUsage = Loadable()
        snapshot.builder = nil
        for resource in EngineResource.allCases where resource != .system {
            lastFetch[resource] = nil
        }
    }

    /// Record the outcome of a fetch; `true` when subscribers should hear
    /// about it. The same value again only moves `updatedAt`; the same error
    /// again changes nothing.
    private func apply<Value: Equatable>(_ result: Result<Value, EngineError>,
                                         to keyPath: WritableKeyPath<EngineSnapshot, Loadable<Value>>) -> Bool {
        let current = snapshot[keyPath: keyPath]
        switch result {
        case .success(let value):
            snapshot[keyPath: keyPath] = Loadable(value: value, error: nil, updatedAt: Date())
            return current.value != value || current.error != nil
        case .failure(let error):
            snapshot[keyPath: keyPath].error = error
            return current.error != error
        }
    }

    private func publish(_ events: [EngineEvent]) {
        let update = EngineUpdate(snapshot: snapshot, events: events)
        for continuation in subscribers.values {
            continuation.yield(update)
        }
    }

    private static func capture<Value>(_ body: () async throws -> Value) async -> Result<Value, EngineError> {
        do {
            return .success(try await body())
        } catch let error as EngineError {
            return .failure(error)
        } catch {
            return .failure(.serviceError(code: "unknown", message: error.localizedDescription))
        }
    }
}

private extension Result {
    var value: Success? {
        if case .success(let value) = self { return value }
        return nil
    }
}
