import Foundation

/// `/var/run/docker.sock` for tools that don't read `DOCKER_HOST`: a root
/// helper points it at the console user's `~/.irekobox/docker.sock`.
///
/// The app asks by writing `on` or `off` to ``requestPath`` (that is all the
/// helper takes from it; the target is always derived from the console
/// user). Turning on remembers what the link pointed at (usually Docker
/// Desktop) and turning off puts that back. If another tool takes the link
/// over later while it's on, the helper leaves it alone — no tug of war —
/// unless the link is missing or dangling.
public enum SocketLink {
    public static let linkPath = "/var/run/docker.sock"
    public static let requestDirectory = "/Users/Shared/Irekobox"
    public static let requestPath = requestDirectory + "/docker-sock"
    public static let statePath = "/Library/Application Support/Irekobox/socket-link.json"
    public static let helperLabel = "com.irekobox.socketlink"

    /// The console user's socket.
    public static func target(home: String) -> String {
        (home as NSString).appendingPathComponent(".irekobox/docker.sock")
    }

    public struct State: Codable, Equatable, Sendable {
        /// What the link pointed at before we took it.
        public var previous: String?
        /// The target we set; nil while off.
        public var linked: String?

        public init(previous: String? = nil, linked: String? = nil) {
            self.previous = previous
            self.linked = linked
        }
    }

    /// What the helper does to the link.
    public enum Action: Equatable, Sendable {
        case none
        case link(to: String)
        case remove
    }

    /// The decision, free of the file system. `current` is where the link
    /// points (nil: missing), `currentIsLive` whether that path exists.
    public static func plan(wanted: Bool, target: String, current: String?, currentIsLive: Bool,
                            state: State) -> (Action, State) {
        var state = state
        if wanted {
            if current == target {
                state.linked = target
                return (.none, state)
            }
            if state.linked == target {
                // Ours before, someone else's now: yield, unless it's broken.
                if current == nil || !currentIsLive { return (.link(to: target), state) }
                return (.none, state)
            }
            // Taking it over: remember what was there.
            state.previous = current
            state.linked = target
            return (.link(to: target), state)
        }
        guard let linked = state.linked else { return (.none, state) }
        let previous = state.previous
        state = State()
        guard current == linked else { return (.none, state) }   // not ours any more
        if let previous { return (.link(to: previous), state) }
        return (.remove, state)
    }

    /// Where a symlink points, or nil.
    public static func readLink(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    /// Replace `path` with a symlink to `target` in one rename.
    public static func makeLink(_ path: String, to target: String) throws {
        let temporary = path + ".irekobox-\(getpid())"
        unlink(temporary)
        guard symlink(target, temporary) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard rename(temporary, path) == 0 else {
            let code = errno
            unlink(temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// The app's view: what the link points at now.
    public enum Status: Equatable, Sendable {
        case ours
        case other(String)
        case missing
    }

    public static func status(home: String) -> Status {
        guard let current = readLink(linkPath) else {
            return FileManager.default.fileExists(atPath: linkPath) ? .other(linkPath) : .missing
        }
        return current == target(home: home) ? .ours : .other(current)
    }

    /// Ask the helper; the directory is shared so the root helper can watch it.
    public static func request(_ on: Bool) throws {
        try FileManager.default.createDirectory(atPath: requestDirectory, withIntermediateDirectories: true)
        try Data((on ? "on" : "off").utf8).write(to: URL(fileURLWithPath: requestPath), options: .atomic)
    }

    public static func requested() -> Bool {
        (try? String(contentsOfFile: requestPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "on"
    }
}
