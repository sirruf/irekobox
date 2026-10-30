import Foundation

/// Explanations for the usual "why doesn't it work / why is it slow" with
/// containers on a Mac: dead ports, memory a VM keeps, slow bind mounts.
/// Pure decisions here; the app gathers the facts.
public enum ContainerCheckup {
    public struct Finding: Hashable, Sendable, Identifiable {
        public enum Level: Int, Comparable, Sendable {
            case ok, info, warning, problem
            public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
        }
        public let level: Level
        public let title: String
        public let detail: String
        /// A concrete next step, when there is one.
        public let fix: String?
        public var id: String { title + detail }

        public init(_ level: Level, _ title: String, _ detail: String, fix: String? = nil) {
            self.level = level
            self.title = title
            self.detail = detail
            self.fix = fix
        }
    }

    // MARK: - Ports

    /// A TCP socket listening inside the container.
    public struct Listener: Hashable, Sendable {
        public let address: String
        public let port: Int

        public var isLoopback: Bool { address == "127.0.0.1" || address == "::1" }
        public var isAny: Bool { address == "0.0.0.0" || address == "::" }
    }

    /// `/proc/net/tcp` and `/proc/net/tcp6` (concatenated): sockets in LISTEN.
    public static func listeners(procNet text: String) -> [Listener] {
        var result: [Listener] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count > 3, fields[3] == "0A" else { continue }     // 0A = LISTEN
            let local = fields[1].split(separator: ":")
            guard local.count == 2, let port = Int(local[1], radix: 16) else { continue }
            guard let address = decode(String(local[0])) else { continue }
            result.append(Listener(address: address, port: port))
        }
        return Array(Set(result)).sorted { ($0.port, $0.address) < ($1.port, $1.address) }
    }

    /// The kernel prints addresses as little-endian 32-bit words.
    static func decode(_ hex: String) -> String? {
        let chars = Array(hex)
        if chars.count == 8, let value = UInt32(hex, radix: 16) {
            return "\(value & 0xff).\((value >> 8) & 0xff).\((value >> 16) & 0xff).\((value >> 24) & 0xff)"
        }
        guard chars.count == 32 else { return nil }
        var bytes: [UInt8] = []
        for word in 0..<4 {
            guard let value = UInt32(String(chars[word * 8..<(word + 1) * 8]), radix: 16) else { return nil }
            bytes += [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8(value >> 24)]
        }
        if bytes.allSatisfy({ $0 == 0 }) { return "::" }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return "::1" }
        // IPv4-mapped (::ffff:a.b.c.d).
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
        }
        return stride(from: 0, to: 16, by: 2).map { String(format: "%x", Int(bytes[$0]) << 8 | Int(bytes[$0 + 1])) }
            .joined(separator: ":")
    }

    public enum Reach: Equatable, Sendable {
        case open
        /// Accepted, then closed at once: the Mac side of a port forward
        /// that found nothing to talk to inside.
        case dropped
        case refused
        case timedOut
        /// No route (macOS Local Network privacy blocks the asking app).
        case unreachable
    }

    /// Why `localhost:hostPort` does or doesn't answer.
    /// - Parameters:
    ///   - host: connecting to 127.0.0.1:hostPort from this Mac.
    ///   - hostOwner: the process listening on the host port (nil: nobody).
    ///   - ownForwarder: whether that process is this container's runtime.
    ///   - inside: listening sockets inside the container (nil: couldn't read).
    ///   - direct: connecting to the container's own address, if tried.
    public static func port(host hostPort: Int, container containerPort: Int, reach host: Reach,
                            hostOwner: String?, ownForwarder: Bool, inside: [Listener]?, direct: Reach?) -> Finding {
        let name = String(localized: "Port \(String(hostPort)) → \(String(containerPort))")
        if host == .open {
            return Finding(.ok, name, String(localized: "Answers on localhost:\(String(hostPort))."))
        }
        if let hostOwner, !ownForwarder {
            return Finding(.problem, name, String(localized: "localhost:\(String(hostPort)) belongs to \(hostOwner), not to this container."),
                           fix: String(localized: "Quit \(hostOwner) or publish the container on another host port."))
        }
        if let inside {
            let matching = inside.filter { $0.port == containerPort }
            if matching.isEmpty {
                let others = inside.map { "\($0.port)" }
                let ports = Array(Set(others)).sorted { Int($0)! < Int($1)! }.joined(separator: ", ")
                if ports.isEmpty {
                    return Finding(.problem, name,
                                   String(localized: "Nothing listens on port \(String(containerPort)) inside the container — nothing listens at all yet."),
                                   fix: String(localized: "Check the logs: the app may still be starting or have failed."))
                }
                return Finding(.problem, name,
                               String(localized: "Nothing listens on port \(String(containerPort)) inside the container (it listens on \(ports))."),
                               fix: String(localized: "Publish the port the app uses, or configure the app for \(String(containerPort))."))
            }
            if matching.allSatisfy(\.isLoopback) {
                return Finding(.problem, name, String(localized: "The app listens on \(matching[0].address):\(String(containerPort)), the container's own localhost, so nothing from outside reaches it."),
                               fix: String(localized: "Make it listen on 0.0.0.0 (e.g. --host 0.0.0.0 or --bind 0.0.0.0)."))
            }
        }
        switch direct {
        case .open?:
            return Finding(.warning, name, String(localized: "The app answers on the container's address but not on localhost:\(String(hostPort)): the port forward is stuck."),
                           fix: String(localized: "Restart the container."))
        case .unreachable?:
            return Finding(.warning, name, String(localized: "This Mac can't reach the container's network: Local Network access may be off for Irekobox."),
                           fix: String(localized: "System Settings › Privacy & Security › Local Network: allow Irekobox (and the app you test with)."))
        default:
            break
        }
        if host == .dropped {
            return Finding(.warning, name, String(localized: "localhost:\(String(hostPort)) accepts connections but closes them at once."),
                           fix: String(localized: "The forward can't reach the app inside: check the logs, or restart the container."))
        }
        if host == .timedOut {
            return Finding(.warning, name, String(localized: "localhost:\(String(hostPort)) doesn't answer in time."),
                           fix: String(localized: "The app may be busy or a firewall drops the connection; check the logs."))
        }
        return Finding(.warning, name, String(localized: "localhost:\(String(hostPort)) refuses connections."),
                       fix: String(localized: "Check the logs; restarting the container re-creates the port forward."))
    }

    // MARK: - Memory

    /// A Linux VM keeps memory it once used: freed pages aren't handed back
    /// to macOS. When the VM holds far more than the container uses, a
    /// restart returns it.
    public static func memory(footprint: Int64, used: Int64, limit: Int64) -> Finding {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        let held = formatter.string(fromByteCount: footprint)
        let inUse = formatter.string(fromByteCount: used)
        // A small VM needs ~350 MB for its kernel and caches whatever it runs.
        let idle = footprint - used
        if idle > 1 << 30 || (limit > 0 && idle > 512 << 20 && Double(footprint) > Double(limit) * 0.6) {
            return Finding(.warning, String(localized: "Memory"), String(localized: "The VM holds \(held) of this Mac's memory while the container uses \(inUse). Linux VMs don't give freed memory back."),
                           fix: String(localized: "Restart the container to return it; a lower memory limit caps it."))
        }
        return Finding(.ok, String(localized: "Memory"), String(localized: "The VM holds \(held); the container uses \(inUse)."))
    }

    // MARK: - Bind mounts

    /// What a bind-mounted folder holds, as far as slowness goes.
    public struct MountProbe: Sendable {
        public let source: String
        public let destination: String
        /// Dependency folders found at the top (node_modules, vendor, …).
        public let heavyFolders: [String]
        /// Files counted (stops at the cap).
        public let fileCount: Int
        public let countCapped: Bool

        public init(source: String, destination: String, heavyFolders: [String], fileCount: Int, countCapped: Bool) {
            self.source = source
            self.destination = destination
            self.heavyFolders = heavyFolders
            self.fileCount = fileCount
            self.countCapped = countCapped
        }
    }

    public static let heavyFolderNames = ["node_modules", "vendor", ".venv", "venv", "target", ".gradle", "Pods", "deps", "_build"]

    /// Shared folders go through virtiofs: every file operation crosses the
    /// VM boundary, so thousands of small files (dependencies, builds) are slow.
    public static func mount(_ probe: MountProbe) -> Finding {
        let folder = (probe.source as NSString).abbreviatingWithTildeInPath
        let title = String(localized: "Folder \(folder)")
        if !probe.heavyFolders.isEmpty {
            let list = probe.heavyFolders.joined(separator: ", ")
            let first = probe.heavyFolders[0]
            let option = "-v \(first.replacingOccurrences(of: ".", with: ""))-cache:\((probe.destination as NSString).appendingPathComponent(first))"
            return Finding(.warning, title, String(localized: "Shared from the Mac with \(list) inside; dependency folders with many small files are slow over a shared folder."),
                           fix: String(localized: "Put \(first) in a named volume: \(option)"))
        }
        if probe.countCapped {
            return Finding(.info, title, String(localized: "Shared from the Mac with more than \(probe.fileCount) files; tools that scan the whole tree will be slow."),
                           fix: String(localized: "Keep generated files in a named volume."))
        }
        return Finding(.ok, title, String(localized: "Shared from the Mac (\(probe.fileCount) files)."))
    }
}
