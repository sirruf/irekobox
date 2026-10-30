import Foundation
import ContainerKit
import os

/// The Docker side of the background agent: the exit recorder always runs
/// (exit codes are only reported to someone waiting), the socket only while
/// enabled in Settings.
public actor DockerHost {
    public let socketPath: String
    private let backend: DockerBackend
    private let api: DockerEngineAPI
    private var server: DockerAPIServer?
    private var enabled = false
    private var lastError: String?
    private let log = Logger(subsystem: "com.irekobox", category: "docker-host")

    public init(backend: DockerBackend, appVersion: String,
                socketPath: String, exitsFile: URL?, supervisorFile: URL? = nil) {
        self.socketPath = socketPath
        self.backend = backend
        api = DockerEngineAPI(backend: backend, host: DockerHostInfo(appVersion: appVersion), socketPath: socketPath,
                              exitsFile: exitsFile, supervisorFile: supervisorFile)
    }

    /// Start recording exits and supervising restart policies. Call once at launch.
    public func start() async {
        await api.supervisor.start()
        await api.exits.start()
        await api.hosts.start()
        await api.health.start()
    }

    /// Alerts after `sequence`, and the newest sequence.
    public func alerts(after sequence: UInt64) async -> ([ContainerAlert], UInt64) {
        (await api.alerts.after(sequence), await api.alerts.latest)
    }

    /// Container name → health status.
    public func healthStatuses() async -> [String: String] {
        await api.health.statuses().mapValues(\.rawValue)
    }

    /// A user stopped or started containers outside the Docker API (the app).
    public func handAction(stopped: Bool, names: [String]) async {
        for name in names {
            if stopped { await api.supervisor.stoppedByHand(name) } else { await api.supervisor.startedByHand(name) }
        }
    }

    /// Listen or stop listening; idempotent.
    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if enabled {
            guard server == nil else { return }
            let server = DockerAPIServer(socketPath: socketPath, router: api.router)
            do {
                try server.start()
                self.server = server
                lastError = nil
            } catch UnixSocketListener.ListenError.inUse(let path) {
                lastError = "Another process is serving \(path)."
                log.error("Docker socket in use: \(path, privacy: .public)")
            } catch {
                lastError = "Couldn't listen on \(socketPath): \(error)"
                log.error("Docker socket failed: \(String(describing: error), privacy: .public)")
            }
        } else {
            server?.stop()
            server = nil
            lastError = nil
        }
    }

    public struct Status: Sendable, Equatable {
        public let enabled: Bool
        public let listening: Bool
        public let socketPath: String
        public let error: String?
    }

    public func status() -> Status {
        Status(enabled: enabled, listening: server != nil, socketPath: socketPath, error: lastError)
    }
}
