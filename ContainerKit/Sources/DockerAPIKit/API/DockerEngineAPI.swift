import Foundation
import ContainerKit

/// Everything the Docker API serves, wired together; the host (agent, or the
/// dev runner) owns the server and the exit recorder's lifetime.
public final class DockerEngineAPI: Sendable {
    public let router: DockerRouter
    public let exits: ExitRecorder
    public let supervisor: Supervisor
    public let hosts: HostsSync
    public let health: HealthMonitor
    public let alerts: AlertLog

    /// `socketPath`: where the API listens, mounted into containers that ask
    /// for the Docker socket.
    public init(backend: DockerBackend, host: DockerHostInfo, socketPath: String? = nil, exitsFile: URL?,
                supervisorFile: URL? = nil) {
        let exits = ExitRecorder(backend: backend, file: exitsFile)
        let supervisor = Supervisor(backend: backend, exits: exits, stateFile: supervisorFile)
        let attaches = AttachRegistry()
        let execs = ExecRegistry()
        let pending = PendingCopies()
        let hosts = HostsSync(backend: backend)
        let alerts = AlertLog()
        supervisor.alerts = alerts
        let health = HealthMonitor(backend: backend)
        let events = EventHub(backend: backend, exits: exits)
        var router = DockerRouter()
        SystemAPI.register(on: &router, backend: backend, host: host)
        ContainersAPI.register(on: &router, backend: backend, exits: exits, attaches: attaches, supervisor: supervisor,
                               pending: pending, hosts: hosts, waits: ExitWaits(), health: health,
                               dockerSocket: socketPath)
        ExecAPI.register(on: &router, backend: backend, attaches: attaches, execs: execs, exits: exits)
        LogsStatsAPI.register(on: &router, backend: backend)
        ImagesAPI.register(on: &router, backend: backend)
        BuildAPI.register(on: &router, backend: backend)
        ArchiveAPI.register(on: &router, backend: backend, pending: pending)
        VolumesAPI.register(on: &router, backend: backend)
        NetworksAPI.register(on: &router, backend: backend)
        EventsAPI.register(on: &router, hub: events)
        DiskUsageAPI.register(on: &router, backend: backend)
        self.router = router
        self.exits = exits
        self.supervisor = supervisor
        self.hosts = hosts
        self.health = health
        self.alerts = alerts
        Task {
            await health.setChangeHandler { container, now, before in
                await events.publish(DockerEvent(
                    type: "container", action: "health_status: \(now.status.rawValue)",
                    actorID: DockerContainer.id(for: container),
                    attributes: container.configuration.labels.merging(
                        ["name": DockerContainer.dockerName(for: container), "image": ContainerModels.familiar(container.configuration.image.reference)]) { $1 },
                    time: Date()))
                let output = now.log.last?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if now.status == .unhealthy {
                    await alerts.add(.unhealthy, container: container.id,
                                     detail: output.isEmpty ? "Health check failed \(now.failingStreak) times" : String(output.prefix(200)))
                } else if now.status == .healthy, before == .unhealthy {
                    await alerts.add(.recovered, container: container.id, detail: "Health check passes again")
                }
            }
        }
    }
}
