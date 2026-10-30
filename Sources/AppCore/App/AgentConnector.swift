import Foundation
import ServiceManagement
import os
import EngineCore

/// Registers the bundled background agent with launchd (`SMAppService`) and
/// connects to it, making sure the running agent is the binary in this bundle.
///
/// Returns `nil` whenever the agent can't be used — e.g. a SwiftPM build without
/// an app bundle, or registration awaiting the user's approval — and the app
/// keeps its in-process store.
@MainActor
final class AgentConnector {
    enum Status: Equatable {
        case disabled
        case notBundled
        case requiresApproval
        case failed(String)
        case connected(pid: Int32)
    }

    private(set) var status: Status = .notBundled
    private let log = Logger(subsystem: "com.irekobox.app", category: "agent")

    private var bundledExecutable: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "IrekoboxAgent")
    }

    private var service: SMAppService { .agent(plistName: AgentConstants.plistName) }

    /// Stop the agent and remove it from launchd (and Login Items).
    func disable() async {
        try? await service.unregister()
        status = .disabled
    }

    var statusDescription: String {
        switch status {
        case .disabled: return String(localized: "Off — state is polled only while the app runs.")
        case .notBundled: return String(localized: "Unavailable in this build (no embedded agent).")
        case .requiresApproval: return String(localized: "Waiting for approval in System Settings › General › Login Items.")
        case .failed(let reason): return String(localized: "Not running: \(reason)")
        case .connected(let pid): return String(localized: "Running (pid \(String(pid))).")
        }
    }

    func connect(configuration: AgentConfiguration) async -> AgentClient? {
        guard let executable = bundledExecutable,
              Bundle.main.bundleURL.appendingPathComponent(
                "Contents/Library/LaunchAgents/\(AgentConstants.plistName)").isFileReadable else {
            status = .notBundled
            return nil
        }
        do {
            try register()
        } catch {
            status = .failed(String(localized: "register: \(error.localizedDescription)"))
            log.error("agent registration failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        if service.status == .requiresApproval {
            status = .requiresApproval
            return nil
        }

        // launchd may still be starting it (or throttling a relaunch, ~10 s).
        var connected = await connectWithRetry(configuration, attempts: 15)
        if connected == nil {
            // An agent left running from a replaced binary (an app update or a
            // rebuild) can refuse every connection. Re-registering makes launchd
            // stop it and start the one in this bundle.
            log.info("agent did not answer; re-registering it")
            try? await service.unregister()
            try? register()
            try? await Task.sleep(for: .seconds(1))
            connected = await connectWithRetry(configuration, attempts: 20)
        }
        guard var (client, info) = connected else {
            status = .failed(String(localized: "agent did not answer"))
            return nil
        }
        if isStale(info, bundled: executable) {
            log.info("restarting stale agent pid \(info.pid) (\(info.executablePath, privacy: .public))")
            if info.executablePath != executable.path {
                // Registered from another copy of the app: re-point launchd here.
                try? await service.unregister()
                try? register()
            } else {
                client.restartAgent()
            }
            client.disconnect()
            try? await Task.sleep(for: .seconds(1))
            guard let fresh = await connectWithRetry(configuration, attempts: 20),
                  !isStale(fresh.1, bundled: executable) else {
                status = .failed(String(localized: "agent restart did not pick up the new binary"))
                return nil
            }
            (client, info) = fresh
        }
        status = .connected(pid: info.pid)
        log.info("connected to agent pid \(info.pid)")
        return client
    }

    private func register() throws {
        switch service.status {
        case .enabled, .requiresApproval:
            return
        default:
            try service.register()
        }
    }

    private func connectWithRetry(_ configuration: AgentConfiguration,
                                  attempts: Int) async -> (AgentClient, AgentInfo)? {
        for attempt in 1...attempts {
            let client = AgentClient()
            if let info = try? await client.connect(configuration: configuration, timeout: .seconds(2)) {
                return (client, info)
            }
            client.disconnect()
            try? await Task.sleep(for: .milliseconds(min(1000, 200 * attempt)))
        }
        return nil
    }

    /// The running agent is another binary than the one in this bundle.
    private func isStale(_ info: AgentInfo, bundled executable: URL) -> Bool {
        if info.protocolVersion != AgentConstants.protocolVersion { return true }
        if info.executablePath != executable.path { return true }
        let bundledModified = (try? FileManager.default.attributesOfItem(atPath: executable.path))?[.modificationDate] as? Date
        guard let bundledModified, let running = info.executableModified else { return false }
        return bundledModified > running
    }
}

private extension URL {
    var isFileReadable: Bool { FileManager.default.isReadableFile(atPath: path) }
}
