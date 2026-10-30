import AppKit
import ContainerKit

/// Another program already listens on a port a container publishes.
struct PortInUse: LocalizedError, Sendable {
    let container: String
    let port: Int
    let command: String
    let pid: Int32
    /// The next free port, offered instead.
    let free: Int

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
            for port in container.configuration.publishedPorts ?? [] where (port.proto ?? "tcp").lowercased() == "tcp" {
                guard let owner = await owner(of: port.hostPort) else { continue }
                let problem = PortInUse(container: id, port: port.hostPort, command: owner.command, pid: owner.pid,
                                        free: await freePort(after: port.hostPort))
                await MainActor.run { NotificationCenter.default.post(name: conflict, object: problem) }
                throw problem
            }
        }
        return guarded
    }

    /// Who listens on TCP `port`, if anyone.
    static func owner(of port: Int) async -> (pid: Int32, command: String)? {
        guard let output = try? await ProcessRunner.run(executable: "/usr/sbin/lsof",
                                                          ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]) else { return nil }
        var pid: Int32?
        var command: String?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p"), pid == nil { pid = Int32(line.dropFirst()) }
            if line.hasPrefix("c"), command == nil { command = String(line.dropFirst()) }
        }
        guard let pid else { return nil }
        return (pid, command ?? String(localized: "unknown", comment: "An unknown program that holds a port"))
    }

    /// The first free port after `port`.
    static func freePort(after port: Int) async -> Int {
        var candidate = port + 1
        while candidate < 65535, await owner(of: candidate) != nil { candidate += 1 }
        return candidate
    }

    /// "[ip:]host:container[/proto]" with the host port changed.
    static func replacingHostPort(_ spec: String, _ old: Int, with new: Int) -> String {
        var parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let index = parts.count >= 3 ? parts.count - 2 : 0
        guard parts.count >= 2, parts[index] == String(old) else { return spec }
        parts[index] = String(new)
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
                Fix(title: String(localized: "Use \(String(conflict.free)) Instead")) {
                    Task { await app?.movePort(of: conflict.container, from: conflict.port, to: conflict.free) }
                },
                Fix(title: other == nil ? String(localized: "Show in Activity Monitor") : String(localized: "Show the Other App")) {
                    if let other {
                        other.activate()
                    } else {
                        NSWorkspace.shared.openApplication(at: URL(filePath: "/System/Applications/Utilities/Activity Monitor.app"),
                                                           configuration: .init())
                    }
                },
            ])
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
