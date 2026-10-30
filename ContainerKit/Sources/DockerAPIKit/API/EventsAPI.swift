import Foundation
import ContainerKit

/// One Docker event.
public struct DockerEvent: Sendable, Equatable {
    public let type: String
    public let action: String
    public let actorID: String
    public let attributes: [String: String]
    public let time: Date

    struct Wire: Encodable {
        struct Actor: Encodable {
            let ID: String
            let Attributes: [String: String]
        }
        let `Type`: String
        let Action: String
        let Actor: Actor
        let scope = "local"
        let time: Int64
        let timeNano: Int64
        // Pre-1.22 fields the docker CLI still reads for containers/images.
        let status: String?
        let id: String?
        let from: String?
    }

    var wire: Wire {
        let legacy = type == "container" || type == "image"
        return Wire(Type: type, Action: action, Actor: .init(ID: actorID, Attributes: attributes),
                    time: Int64(time.timeIntervalSince1970),
                    timeNano: Int64(time.timeIntervalSince1970 * 1_000_000_000),
                    status: legacy ? action : nil, id: legacy ? actorID : nil,
                    from: type == "container" ? attributes["image"] : nil)
    }
}

/// Docker events, derived from what changed between snapshots of the engine
/// (taken every second while someone listens), so changes made anywhere —
/// the API, the app, the `container` CLI, a crash — are reported alike.
/// Changes within one interval coalesce; history covers only listened time.
public actor EventHub {
    struct ContainerState: Equatable {
        let id: String
        let name: String
        let image: String
        let labels: [String: String]
        let running: Bool
        let started: String?
    }

    struct Snapshot {
        var containers: [String: ContainerState] = [:]
        /// reference → image ID
        var images: [String: String] = [:]
        var volumes: Set<String> = []
        /// name → ID
        var networks: [String: String] = [:]
    }

    private let backend: DockerBackend
    private let exits: ExitRecorder?
    private var snapshot: Snapshot?
    private var history: [DockerEvent] = []
    private var listeners: [UUID: AsyncStream<DockerEvent>.Continuation] = [:]
    private var poller: Task<Void, Never>?
    private var tick = 0
    let interval: Duration

    public init(backend: DockerBackend, exits: ExitRecorder? = nil, interval: Duration = .seconds(1)) {
        self.backend = backend
        self.exits = exits
        self.interval = interval
    }

    /// Past events (oldest first) and the live ones from now on.
    func subscribe() async -> (past: [DockerEvent], live: AsyncStream<DockerEvent>, id: UUID) {
        if snapshot == nil { snapshot = await take(full: true) }   // baseline first: no burst of "create"s
        let (stream, continuation) = AsyncStream<DockerEvent>.makeStream()
        let id = UUID()
        listeners[id] = continuation
        if poller == nil {
            poller = Task { [weak self, interval] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    await self?.poll()
                }
            }
        }
        return (history, stream, id)
    }

    func unsubscribe(_ id: UUID) {
        listeners.removeValue(forKey: id)?.finish()
        if listeners.isEmpty {
            poller?.cancel()
            poller = nil
            snapshot = nil      // a later listener starts from a fresh baseline
        }
    }

    func poll() async {
        tick += 1
        // Containers every tick; the rest (CLI calls) every third.
        guard let old = snapshot else { return }
        let full = tick % 3 == 0
        let new = await take(full: full, keeping: old)
        snapshot = new
        let now = Date()
        var events: [DockerEvent] = []
        events += await containerEvents(old.containers, new.containers, now)
        if full {
            events += Self.imageEvents(old.images, new.images, now)
            events += Self.volumeEvents(old.volumes, new.volumes, now)
            events += Self.networkEvents(old.networks, new.networks, now)
        }
        for event in events { publish(event) }
    }

    func publish(_ event: DockerEvent) {
        history.append(event)
        if history.count > 1000 { history.removeFirst(history.count - 1000) }
        for listener in listeners.values { listener.yield(event) }
    }

    private func take(full: Bool, keeping old: Snapshot = Snapshot()) async -> Snapshot {
        var snapshot = old
        if let containers = try? await backend.listContainers(all: true) {
            snapshot.containers = [:]
            for container in containers where !container.isSystem {
                let id = DockerContainer.id(for: container)
                snapshot.containers[id] = ContainerState(
                    id: id, name: container.id, image: ContainerModels.familiar(container.configuration.image.reference),
                    labels: container.configuration.labels, running: container.state.isRunning,
                    started: container.status.startedDate)
            }
        }
        guard full else { return snapshot }
        if let images = try? await ImageDirectory(backend: backend).all() {
            snapshot.images = [:]
            for image in images {
                for reference in image.references { snapshot.images[reference.reference] = image.id }
            }
        }
        if let volumes = try? await backend.listVolumes() { snapshot.volumes = Set(volumes.map(\.name)) }
        if let networks = try? await NetworkDirectory(backend: backend).all() {
            snapshot.networks = Dictionary(networks.filter { $0.network != nil }.map { ($0.name, $0.id) }) { first, _ in first }
        }
        return snapshot
    }

    // MARK: - Diffs

    func containerEvents(_ old: [String: ContainerState], _ new: [String: ContainerState], _ now: Date) async -> [DockerEvent] {
        func event(_ action: String, _ state: ContainerState, _ extra: [String: String] = [:]) -> DockerEvent {
            var attributes = state.labels
            attributes["name"] = state.name
            attributes["image"] = state.image
            attributes.merge(extra) { $1 }
            return DockerEvent(type: "container", action: action, actorID: state.id, attributes: attributes, time: now)
        }
        func die(_ state: ContainerState) async -> DockerEvent {
            var code = "0"
            if let exits, let container = try? await backend.listContainers(all: true).first(where: { $0.id == state.name }),
               let exit = await exits.exit(for: container) {
                code = String(exit.code)
            }
            return event("die", state, ["exitCode": code])
        }
        var events: [DockerEvent] = []
        for (id, state) in new.sorted(by: { $0.key < $1.key }) {
            guard let before = old[id] else {
                events.append(event("create", state))
                if state.running { events.append(event("start", state)) }
                continue
            }
            if before.running && !state.running {
                events.append(await die(state))
            } else if !before.running && state.running {
                events.append(event("start", state))
            } else if before.running && state.running && before.started != state.started {
                events.append(await die(before))       // restarted within one interval
                events.append(event("start", state))
            }
        }
        for (id, state) in old.sorted(by: { $0.key < $1.key }) where new[id] == nil {
            if state.running { events.append(await die(state)) }
            events.append(event("destroy", state))
        }
        return events
    }

    static func imageEvents(_ old: [String: String], _ new: [String: String], _ now: Date) -> [DockerEvent] {
        var events: [DockerEvent] = []
        func familiar(_ reference: String) -> String { ImageReference(reference)?.familiar ?? reference }
        for (reference, id) in new.sorted(by: { $0.key < $1.key }) where old[reference] != id {
            events.append(DockerEvent(type: "image", action: "tag", actorID: id,
                                      attributes: ["name": familiar(reference)], time: now))
        }
        for (reference, id) in old.sorted(by: { $0.key < $1.key }) where new[reference] != id {
            events.append(DockerEvent(type: "image", action: "untag", actorID: id,
                                      attributes: ["name": familiar(reference)], time: now))
        }
        let gone = Set(old.values).subtracting(new.values)
        for id in gone.sorted() {
            events.append(DockerEvent(type: "image", action: "delete", actorID: id, attributes: ["name": id], time: now))
        }
        return events
    }

    static func volumeEvents(_ old: Set<String>, _ new: Set<String>, _ now: Date) -> [DockerEvent] {
        new.subtracting(old).sorted().map {
            DockerEvent(type: "volume", action: "create", actorID: $0, attributes: ["driver": "local"], time: now)
        } + old.subtracting(new).sorted().map {
            DockerEvent(type: "volume", action: "destroy", actorID: $0, attributes: ["driver": "local"], time: now)
        }
    }

    static func networkEvents(_ old: [String: String], _ new: [String: String], _ now: Date) -> [DockerEvent] {
        new.filter { old[$0.key] == nil }.sorted { $0.key < $1.key }.map {
            DockerEvent(type: "network", action: "create", actorID: $0.value, attributes: ["name": $0.key, "type": "bridge"], time: now)
        } + old.filter { new[$0.key] == nil }.sorted { $0.key < $1.key }.map {
            DockerEvent(type: "network", action: "destroy", actorID: $0.value, attributes: ["name": $0.key, "type": "bridge"], time: now)
        }
    }
}

/// `GET /events`.
public enum EventsAPI {
    public static func register(on router: inout DockerRouter, hub: EventHub) {
        router.add("GET", "/events") { request in
            await respond { try await events(request, hub) }
        }
    }

    static func matches(_ event: DockerEvent, _ filters: DockerFilters) -> Bool {
        func any(_ key: String, _ test: (String) -> Bool) -> Bool {
            filters[key].isEmpty || filters[key].contains(where: test)
        }
        let isContainer = event.type == "container"
        return any("type") { $0 == event.type }
            && any("event") { $0 == event.action || event.action.hasPrefix($0 + ":") }   // health_status: …
            && any("container") { name in
                isContainer && (event.attributes["name"] == name || event.actorID.hasPrefix(name))
            }
            && any("image") { image in
                event.attributes["image"] == image || (event.type == "image" && (event.attributes["name"] == image || event.actorID == image))
            }
            && any("volume") { event.type == "volume" && event.actorID == $0 }
            && any("network") { event.type == "network" && (event.actorID.hasPrefix($0) || event.attributes["name"] == $0) }
            && filters.matchesLabels(event.attributes)
    }

    static func events(_ request: DockerRequest, _ hub: EventHub) async throws -> HTTPResponse {
        let filters = try DockerFilters(query: request.query["filters"])
        try filters.validate(["type", "event", "container", "image", "label", "volume", "network",
                              "daemon", "plugin", "node", "service", "secret", "config", "scope"])
        func moment(_ name: String) throws -> Date? {
            guard let text = request.query[name], !text.isEmpty else { return nil }
            guard let date = DockerTime.moment(text) else { throw DockerAPIError.badParameter("invalid \(name): \(text)") }
            return date
        }
        let since = try moment("since")
        let until = try moment("until")
        let (past, live, id) = await hub.subscribe()
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        func send(_ event: DockerEvent) {
            if let data = try? JSONEncoder().encode(event.wire) { continuation.yield(data + Data("\n".utf8)) }
        }
        let task = Task {
            defer {
                continuation.finish()
                Task { await hub.unsubscribe(id) }
            }
            if let since {
                for event in past where event.time >= since && (until.map { event.time <= $0 } ?? true)
                    && matches(event, filters) {
                    send(event)
                }
            }
            if let until, until <= Date() { return }
            // Stop at `until` even if nothing happens.
            let deadline = until.map { date in
                Task {
                    try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
                    continuation.finish()
                }
            }
            for await event in live {
                if Task.isCancelled { break }
                if let until, event.time > until { break }
                if matches(event, filters) { send(event) }
            }
            deadline?.cancel()
        }
        continuation.onTermination = { _ in
            task.cancel()
            Task { await hub.unsubscribe(id) }
        }
        return HTTPResponse(status: 200, headers: [("Content-Type", "application/json")], body: .stream(stream))
    }
}
