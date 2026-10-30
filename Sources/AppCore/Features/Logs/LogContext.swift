import Foundation

/// What happens around a log: the followed containers and their neighbours
/// (same project) stopping, starting and failing health checks. The followed
/// containers' own changes become notes in the log; a neighbour's change
/// explains an error that follows it, once.
struct LogContext {
    /// A related container as it is now.
    struct State: Equatable {
        /// Service name in a project, else the container's name.
        var name: String
        var running: Bool
        var health: String?
        /// When it last started: a new date while running means it restarted
        /// between two looks.
        var started: Date? = nil
    }

    struct Event: Equatable {
        enum Kind: Equatable { case stopped, started, restarted, unhealthy, healthy }
        let containerID: String
        let name: String
        let kind: Kind
        let time: Date
        /// When it stopped before this start, for "restarted at".
        var stoppedAt: Date?
        var explained = false
    }

    /// Containers whose output this log shows.
    var followed: Set<String> = []
    private(set) var events: [Event] = []
    private var states: [String: State] = [:]

    /// Errors this long after a neighbour's change are blamed on it even if
    /// they don't name it.
    static let closeWindow: TimeInterval = 30
    /// Errors naming a neighbour are blamed on its change this long after.
    static let namedWindow: TimeInterval = 300

    init(followed: Set<String> = []) {
        self.followed = followed
    }

    /// Take the latest states; returns notes for the followed containers' own
    /// changes. The first sight of a container is no change.
    mutating func update(_ current: [String: State], at time: Date = Date()) -> [(text: String, note: LogNote)] {
        var notes: [(String, LogNote)] = []
        for id in current.keys.sorted() {
            guard let now = current[id] else { continue }
            defer { states[id] = now }
            guard let before = states[id] else { continue }
            var kinds: [Event.Kind] = []
            if before.running && !now.running { kinds.append(.stopped) }
            if !before.running && now.running { kinds.append(.started) }
            if before.running && now.running, let was = before.started, let started = now.started, started != was {
                kinds.append(.started)
            }
            if now.health == "unhealthy" && before.health != "unhealthy" { kinds.append(.unhealthy) }
            if now.health == "healthy" && before.health == "unhealthy" { kinds.append(.healthy) }
            for kind in kinds {
                let stoppedAt = kind == .started
                    ? events.last { $0.containerID == id && $0.kind == .stopped }?.time : nil
                // A restart seen only by its new start date: date it by that start.
                let at = kind == .started ? min(now.started ?? time, time) : time
                events.append(Event(containerID: id, name: now.name, kind: kind, time: at, stoppedAt: stoppedAt))
                if followed.contains(id) {
                    notes.append((Self.ownText(now.name, before.running && kind == .started ? .restarted : kind), LogNote()))
                }
            }
        }
        events.removeAll { time.timeIntervalSince($0.time) > Self.namedWindow }
        return notes
    }

    /// A note explaining `line` by a neighbour's recent change, if one fits
    /// and hasn't explained an error yet.
    mutating func explain(_ line: String, level: LogEntry.Level, at time: Date = Date()) -> (text: String, note: LogNote)? {
        guard level >= .warning else { return nil }
        let lowered = line.lowercased()
        for index in events.indices.reversed() {
            let event = events[index]
            guard !event.explained, !followed.contains(event.containerID), event.kind != .healthy else { continue }
            let age = time.timeIntervalSince(event.time)
            let named = lowered.contains(event.name.lowercased()) || lowered.contains(event.containerID.lowercased())
            let stillDown: Bool
            switch event.kind {
            case .stopped: stillDown = states[event.containerID]?.running == false
            case .unhealthy: stillDown = states[event.containerID]?.health == "unhealthy"
            case .started, .restarted, .healthy: stillDown = false
            }
            guard age >= -5, age <= Self.closeWindow || (named && (stillDown || age <= Self.namedWindow)) else { continue }
            // One explanation per change of that container.
            for other in events.indices where events[other].containerID == event.containerID {
                events[other].explained = true
            }
            return (Self.explanation(event, stillDown: stillDown),
                    LogNote(containerID: event.containerID, linkTitle: String(localized: "Show \(event.name) logs")))
        }
        return nil
    }

    static func ownText(_ name: String, _ kind: Event.Kind) -> String {
        switch kind {
        case .stopped: String(localized: "\(name) stopped")
        case .started: String(localized: "\(name) started")
        case .restarted: String(localized: "\(name) restarted")
        case .unhealthy: String(localized: "\(name) is failing its health check")
        case .healthy: String(localized: "\(name) passes its health check again")
        }
    }

    static func explanation(_ event: Event, stillDown: Bool) -> String {
        let at = clock(event.time)
        switch event.kind {
        case .stopped where stillDown:
            return String(localized: "\(event.name) has been stopped since \(at) — errors reaching it are expected until it's back.")
        case .stopped:
            return String(localized: "\(event.name) was restarting at \(at) — errors around then are expected.")
        case .started, .restarted:
            return String(localized: "\(event.name) was restarting at \(clock(event.stoppedAt ?? event.time)) — errors around then are expected.")
        case .unhealthy:
            return String(localized: "\(event.name) has been failing its health check since \(at) — it may be the cause.")
        case .healthy:
            return ""
        }
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}
