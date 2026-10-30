import AppKit
import Darwin
import ContainerKit

/// Another program already listens on a port a container publishes.
struct PortInUse: LocalizedError, Sendable {
    let container: String
    let port: Int
    let command: String
    let pid: Int32
    /// The next free port, offered instead.
    let free: Int?

    var errorDescription: String? {
        String(localized: "Port \(String(port)) is already used by another app on this Mac (\(command), PID \(String(pid))).")
    }
}

/// Checks a container's published ports before it starts, so a taken port is
/// a clear message with fixes instead of a container nobody can reach.
enum PortCheck {
    static let conflict = Notification.Name("com.irekobox.portInUse")

    /// The engine with the check before every start.
    static func guarding(_ engine: XPCEngine) -> XPCEngine {
        let plain = engine
        var guarded = engine
        guarded.beforeStart = { id in
            guard let container = try? await plain.inspectContainer(id) else { return }
            let ports = bindings(container.configuration.publishedPorts ?? [])
            let blocked = await withTaskGroup(of: (Int, Int32).self) { group in
                // Bound parallelism even for a large published-port list.
                var next = 0
                func enqueue() {
                    guard next < ports.count else { return }
                    let index = next
                    let port = ports[index]
                    next += 1
                    group.addTask { (index, await inUse(port: port.hostPort, address: port.hostAddress) ? EADDRINUSE : 0) }
                }
                for _ in 0..<min(8, ports.count) { enqueue() }
                var blocked: [Int] = []
                for await (index, error) in group {
                    if error == EADDRINUSE { blocked.append(index) }
                    enqueue()
                }
                return blocked.sorted()
            }
            for index in blocked {
                try Task.checkCancellation()
                let port = ports[index]
                // Only a failed bind needs a process lookup. Other socket errors
                // belong to the runtime; don't misreport them as another app.
                let owner = await owner(of: port.hostPort, address: port.hostAddress)
                let problem = PortInUse(container: id, port: port.hostPort,
                                        command: owner?.command ?? String(localized: "unknown", comment: "An unknown program that holds a port"),
                                        pid: owner?.pid ?? 0,
                                        free: await freePort(after: port.rangeStart, address: port.hostAddress, count: port.rangeCount)
                                            .map { $0 + port.hostPort - port.rangeStart })
                await MainActor.run { NotificationCenter.default.post(name: conflict, object: problem) }
                throw problem
            }
        }
        return guarded
    }

    struct Binding: Sendable {
        let hostPort: Int
        let hostAddress: String?
        let rangeStart: Int
        let rangeCount: Int
    }

    /// Inspect stores a port range as one mapping. Probe every port in it.
    static func bindings(_ ports: [Container.PublishedPort]) -> [Binding] {
        ports.flatMap { port -> [Binding] in
            let count = port.count ?? 1
            guard (port.proto ?? "tcp").lowercased() == "tcp", (1...65535).contains(port.hostPort),
                  count > 0, count <= 65536 - port.hostPort else { return [] }
            return (0..<count).map {
                Binding(hostPort: port.hostPort + $0, hostAddress: port.hostAddress,
                        rangeStart: port.hostPort, rangeCount: count)
            }
        }
    }

    /// Who listens on TCP `port`, if anyone.
    static func owner(of port: Int, address: String? = nil) async -> (pid: Int32, command: String)? {
        guard let output = try? await ProcessRunner.run(executable: "/usr/sbin/lsof",
                                                          ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpcn"]) else { return nil }
        return owner(in: output, port: port, address: address)
    }

    /// lsof can list several listeners on distinct local addresses.
    static func owner(in output: String, port: Int, address: String? = nil) -> (pid: Int32, command: String)? {
        var pid: Int32?
        var command: String?
        let host = address ?? "0.0.0.0"
        let wildcard = host == "0.0.0.0" || host == "::"
        // A wildcard listener holds every address, so it is the owner too.
        func holds(_ endpoint: String) -> Bool {
            wildcard || endpoint == "*:\(port)" || endpoint == "[::]:\(port)" || endpoint == "0.0.0.0:\(port)"
                || endpoint == "\(host):\(port)" || endpoint == "[\(host)]:\(port)"
        }
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()); command = nil }
            if line.hasPrefix("c") { command = String(line.dropFirst()) }
            if line.hasPrefix("n"), let pid {
                if holds(String(line.dropFirst())) {
                    return (pid, command ?? String(localized: "unknown", comment: "An unknown program that holds a port"))
                }
            }
        }
        return nil
    }

    /// Whether another program listens on `port` where clients of the
    /// published address could reach it — as strict as asking lsof for any
    /// listener, which this used to do, but without a process per port.
    ///
    /// With SO_REUSEADDR (as the runtime binds) a specific address binds next
    /// to another program's wildcard listener and a wildcard next to its
    /// loopback one, yet `localhost` clients would end up there. So: bind as
    /// the runtime would, on the published and the wildcard addresses; if that
    /// works, bind the wildcards without SO_REUSEADDR, which any bound socket
    /// on the port refuses; only then ask lsof, since a closing connection
    /// (TIME_WAIT) refuses that bind too.
    static func inUse(port: Int, address: String?) async -> Bool {
        let host = address ?? "0.0.0.0"
        var addresses = [host]
        if host.contains(":") {
            if host != "::" { addresses.append("::") }
        } else {
            if host != "0.0.0.0" { addresses.append("0.0.0.0") }
            addresses.append("::")
        }
        if addresses.contains(where: { bindError(port: port, address: $0) == EADDRINUSE }) { return true }
        let strict = ["0.0.0.0", "::"].contains { bindError(port: port, address: $0, reuse: false) == EADDRINUSE }
        guard strict else { return false }
        return await owner(of: port) != nil
    }

    /// A short-lived bind using the TCP forwarder's SO_REUSEADDR setting and
    /// the system's IPv6 default. No listen/connect, and every path closes it.
    static func bindError(port: Int, address: String? = nil, reuse: Bool = true) -> Int32? {
        guard (0...65535).contains(port) else { return EINVAL }
        let host = address ?? "0.0.0.0"
        let family = host.contains(":") ? AF_INET6 : AF_INET
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        var flag: Int32 = reuse ? 1 : 0
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &flag, socklen_t(MemoryLayout.size(ofValue: flag))) == 0 else { return errno }
        if family == AF_INET6 {
            var target = sockaddr_in6()
            target.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            target.sin6_family = sa_family_t(AF_INET6)
            target.sin6_port = UInt16(port).bigEndian
            guard inet_pton(AF_INET6, host, &target.sin6_addr) == 1 else { return EINVAL }
            return withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 ? nil : errno
                }
            }
        }
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &target.sin_addr) == 1 else { return EINVAL }
        return withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 ? nil : errno
            }
        }
    }

    /// The first bindable port after `port`, on the same published address.
    static func freePort(after port: Int, address: String? = nil, count: Int = 1) async -> Int? {
        guard (0..<65535).contains(port), count > 0, count <= 65535 - port else { return nil }
        var candidate = port + 1
        while candidate <= 65536 - count {
            var blocked: Int?
            for offset in 0..<count {
                guard !Task.isCancelled else { return nil }
                if await inUse(port: candidate + offset, address: address) {
                    blocked = candidate + offset
                    break
                }
            }
            guard let blocked else { return candidate }
            candidate = blocked + 1
        }
        return nil
    }

    /// "[ip:]host:container[/proto]" with the host port changed.
    static func replacingHostPort(_ spec: String, _ old: Int, with new: Int) -> String {
        var parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let index = parts.count >= 3 ? parts.count - 2 : 0
        guard parts.count >= 2 else { return spec }
        if parts[index] == String(old) {
            parts[index] = String(new)
        } else {
            let range = parts[index].split(separator: "-")
            guard range.count == 2, let start = Int(range[0]), let end = Int(range[1]),
                  start <= old, old <= end else { return spec }
            let movedStart = start + new - old
            let movedEnd = end + new - old
            guard movedStart > 0, movedEnd <= 65535 else { return spec }
            parts[index] = "\(movedStart)-\(movedEnd)"
        }
        return parts.joined(separator: ":")
    }
}

/// An error with one-click fixes, shown at the bottom of the window.
struct Problem: Identifiable {
    struct Fix: Identifiable {
        let title: String
        let action: @MainActor () -> Void
        var id: String { title }
    }

    let id = UUID()
    let title: String
    let message: String
    var fixes: [Fix] = []

    /// Plain toasts with the same text step aside for this one.
    @MainActor static var handled: Set<String> = []

    /// "shop/web" for a compose service, else its name.
    @MainActor
    private static func name(_ id: String, _ app: AppState?) -> String {
        guard let container = app?.model.containers.first(where: { $0.id == id }),
              let project = ContainerList.project(of: container) else { return id }
        return "\(project)/\(container.serviceName)"
    }

    @MainActor
    static func portInUse(_ conflict: PortInUse, app: AppState?) -> Problem {
        handled.insert(conflict.errorDescription ?? "")
        let other = NSRunningApplication(processIdentifier: conflict.pid)
        return Problem(
            title: String(localized: "Couldn't start \(name(conflict.container, app))"),
            message: conflict.errorDescription ?? "",
            fixes: [
                conflict.free.map { free in
                    Fix(title: String(localized: "Use \(String(free)) Instead")) {
                        Task { await app?.movePort(of: conflict.container, from: conflict.port, to: free) }
                    }
                },
                Fix(title: other == nil ? String(localized: "Show in Activity Monitor") : String(localized: "Show the Other App")) {
                    if let other {
                        other.activate()
                    } else {
                        NSWorkspace.shared.openApplication(at: URL(filePath: "/System/Applications/Utilities/Activity Monitor.app"),
                                                           configuration: .init())
                    }
                },
            ].compactMap { $0 })
    }
}

extension AppState {
    /// Recreate `name` with its host port `port` moved to `free`.
    func movePort(of name: String, from port: Int, to free: Int) async {
        problem = nil
        await perform {
            let container = try await engine.inspectContainer(name)
            var edits = ContainerRecreate.currentEdits(for: container)
            edits.ports = edits.ports.map { PortCheck.replacingHostPort($0, port, with: free) }
            try await engine.recreateContainer(container, edits: edits)
        }
    }
}
