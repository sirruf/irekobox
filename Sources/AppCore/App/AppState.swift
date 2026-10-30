import Foundation
import AppKit
import os
import Observation
import ContainerKit
import StackKit
import EngineCore
import MCPKit
import WidgetKit

/// Root application state: owns the engine (and the raw CLI for flows that run
/// arbitrary `container` argv), and tracks the service gate.
@MainActor
@Observable
public final class AppState {
    /// The engine every screen talks to: XPC to `container-apiserver`, with the
    /// CLI as fallback for what XPC doesn't cover.
    private(set) var engine: any ContainerEngine
    /// Raw CLI for docker-run translation, and migration.
    private(set) var cli: ContainerCLI
    private(set) var composeRunner: ComposeRunner

    /// Bumped when the engine is replaced; the root view keys its content on it
    /// so view models are rebuilt instead of holding the old engine.
    private(set) var engineGeneration = 0

    /// Polled engine state shared by every window and the menu bar.
    let model: EngineModel
    var lastError: String?
    /// The last failed user action, shown as a toast (never swallowed).
    var actionError: String?

    /// A Run sheet to show (⌘N, "Run…" on an image).
    var runRequest: RunRequest?
    /// Latest apple/container release, for "update available".
    let updates = ContainerUpdateCheck()
    /// Updates of Irekobox itself (when an appcast is configured).
    public let appUpdater = AppUpdater()
    /// Newer images published for tags in use.
    let imageUpdates = ImageUpdateCheck()

    /// The last day of CPU, memory, network and disk use per container.
    let statsRecorder = StatsRecorder()

    /// The ⌘K command palette is open.
    public var showPalette = false
    /// Text to start the palette with (typed into Overview's search field).
    public var paletteQuery = ""
    /// A container to select once the Containers screen shows it.
    var revealContainer: String?
    /// A compose project to open once the Compose screen shows.
    var revealProject: String?
    /// A cluster to open once the Kubernetes screen shows.
    var revealCluster: String?
    /// A volume whose files to show once the Volumes screen shows.
    var browseVolume: String?
    /// Bumped to open the Settings window from where SwiftUI can.
    var settingsRequest = 0
    /// A folder the next Files tab opens at (Browse Files on a volume).
    var pendingFilesPath: String?
    /// A container page to open once the Containers screen shows.
    var openContainerPage: ContainerPageRequest?

    /// Show a container's page on `tab`, from anywhere.
    func openContainer(_ id: String, tab: ContainerDetailView.DetailTab = .overview) {
        section = .containers
        openContainerPage = ContainerPageRequest(id: id, tab: tab)
    }

    /// Open the Run sheet, optionally for a given image.
    public func requestRun(image: String = "") {
        var configuration = RunConfiguration()
        configuration.image = image
        runRequest = RunRequest(configuration: configuration)
    }

    /// Run Container with the form filled in, or on the paste tab.
    func requestRun(_ configuration: RunConfiguration, paste: Bool = false) {
        runRequest = RunRequest(configuration: configuration, paste: paste)
    }

    /// Selected sidebar destination; restored on the next launch.
    public var section: SidebarSection =
        SidebarSection(rawValue: UserDefaults.standard.string(forKey: "sidebarSection") ?? "") ?? .overview {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: "sidebarSection") }
    }

    /// Bumped by the global Refresh command (⌘R). Screens not backed by the
    /// store observe it via `.task(id: app.refreshTick)` to reload on demand.
    private(set) var refreshTick = 0

    /// Latest known service status. `nil` unless services are running.
    var systemStatus: SystemStatus? { model.snapshot.service.status }
    var diskUsage: SystemDiskUsage? { model.snapshot.diskUsage.value }
    var builder: BuilderStatus? { model.snapshot.builder }
    public var servicesRunning: Bool { model.snapshot.service.isRunning }

    /// Whether the `container` binary (Apple Containerization CLI) is installed
    /// at the configured path. Re-evaluated each access so a re-check is live.
    public var binaryAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: Settings.shared.binaryPath)
    }

    /// `container --version`, read at launch and on re-check; nil until read
    /// or while the binary is missing.
    private(set) var cliVersionOutput: String?
    /// The installed `container` is new enough (assumed until the version is read).
    public var cliSupported: Bool {
        cliVersionOutput.map(ContainerInstaller.isSupported(versionOutput:)) ?? true
    }

    /// The first-run setup was finished (or wasn't needed: the engine was
    /// already running when this version first launched).
    public var setupCompleted = UserDefaults.standard.bool(forKey: "setupCompleted") {
        didSet { UserDefaults.standard.set(setupCompleted, forKey: "setupCompleted") }
    }
    /// The setup flow is on screen, so reaching "running" mid-flow doesn't skip its last step.
    var setupInProgress = false

    public func checkCLIVersion() async {
        guard binaryAvailable else {
            cliVersionOutput = nil
            return
        }
        do {
            cliVersionOutput = String(decoding: try await cli.data(["--version"]), as: UTF8.self)
        } catch {
            // Leave the previous reading; a broken binary shows up as a service error.
        }
    }

    @ObservationIgnored private var activityObservers: [NSObjectProtocol] = []

    /// In-process store: the source until the agent is connected, and the
    /// fallback whenever it isn't.
    @ObservationIgnored private let localStore: EngineStore
    @ObservationIgnored private var agent: AgentClient?
    @ObservationIgnored private let agentConnector = AgentConnector()
    @ObservationIgnored private let notifier = AlertNotifier()
    /// Container name → health status ("starting", "healthy", "unhealthy").
    public private(set) var health: [String: String] = [:]
    /// Bumped to ask for the main window (e.g. from a notification).
    public internal(set) var mainWindowRequest = 0
    /// An error the app knows how to fix, shown with its fixes.
    var problem: Problem?
    /// A window to open, from a link (the root view opens it).
    var windowRequest: WindowRequest?
    /// Human-readable agent status for Settings.
    private(set) var agentStatus = ""

    /// Keep polling (and, later, restart policies and the Docker socket)
    /// running in a background agent when the app is closed.
    public private(set) var backgroundAgentEnabled =
        // bool(forKey:) also reads "NO" from a -backgroundAgentEnabled launch argument.
        UserDefaults.standard.object(forKey: "backgroundAgentEnabled") == nil
            ? true : UserDefaults.standard.bool(forKey: "backgroundAgentEnabled")

    public init() {
        let path = Settings.shared.binaryPath
        let cli = ContainerCLI(binaryPath: path)
        let engine = PortCheck.guarding(XPCEngine(fallback: CLIEngine(cli: cli, stream: CLIStream(binaryPath: path))))
        self.cli = cli
        self.engine = engine
        self.composeRunner = ComposeRunner(runner: cli)
        let store = EngineStore(engine: engine, intervals: Self.intervals())
        self.localStore = store
        self.model = EngineModel(source: store)
        Task { await store.startPolling() }
        observeWindowVisibility()
        Task { await connectAgent() }
        Task { [updates] in await updates.checkIfDue() }
        Task { [appUpdater] in await appUpdater.checkIfDue() }
        imageUpdates.onNewUpdate = { [notifier] reference in notifier.notifyImageUpdate(reference) }
        notifier.onOpenImage = { [weak self] _ in
            self?.section = .images
            self?.mainWindowRequest += 1
        }
        // Once the lists are in, then hourly (the check itself runs daily).
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled, let self {
                await self.imageUpdates.checkIfDue(images: self.model.images, containers: self.model.containers)
                try? await Task.sleep(for: .seconds(3600))
            }
        }
        Task { await checkCLIVersion() }
        openFromLaunchArguments()
        listenForAssistantApprovals()
        NotificationCenter.default.addObserver(forName: PortCheck.conflict, object: nil, queue: .main) { [weak self] note in
            guard let conflict = note.object as? PortInUse else { return }
            MainActor.assumeIsolated { self?.problem = Problem.portInUse(conflict, app: self) }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled, let self {
                self.writeWidgetSnapshot()
                self.rememberWhatRuns()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        Task { [weak self, statsRecorder] in
            await statsRecorder.run {
                let containers = self?.model.containers ?? []
                return (self?.engine ?? engine,
                        containers.filter { $0.state.isRunning }.map(\.id),
                        Set(containers.map(\.id)))
            }
        }
    }

    private static func intervals() -> EngineStore.Intervals {
        EngineStore.Intervals(containers: .milliseconds(Int(Settings.shared.refreshSeconds * 1000)))
    }

    private static func agentConfiguration() -> AgentConfiguration {
        AgentConfiguration(binaryPath: Settings.shared.binaryPath,
                           containersIntervalMilliseconds: Int(Settings.shared.refreshSeconds * 1000),
                           dockerSocketEnabled: UserDefaults.standard.bool(forKey: "dockerSocketEnabled"),
                           startEngineAtLogin: UserDefaults.standard.bool(forKey: "startEngineAtLogin"))
    }

    /// Start the `container` services at login (through the agent); off by default.
    public private(set) var startEngineAtLogin = UserDefaults.standard.bool(forKey: "startEngineAtLogin")

    public func setStartEngineAtLogin(_ enabled: Bool) {
        guard enabled != startEngineAtLogin else { return }
        startEngineAtLogin = enabled
        UserDefaults.standard.set(enabled, forKey: "startEngineAtLogin")
        let configuration = Self.agentConfiguration()
        Task { await agent?.updateConfiguration(configuration) }
    }

    /// An appcast is configured, so the app can update itself.
    public var appUpdatesAvailable: Bool { AppUpdater.appcastURL != nil }

    /// Bring up the Settings window (where updates are shown).
    public func openSettings() {
        NSApplication.shared.activate()
        NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// Tell the agent's supervisor about a stop or start by the user: a
    /// container stopped by hand must not be restarted by its policy.
    public func noteHandAction(stopped: Bool, _ ids: [String]) {
        agent?.handAction(stopped: stopped, names: ids)
    }

    // MARK: - Docker API socket (served by the agent)

    /// Serve the Docker Engine API; off until the user turns it on.
    public private(set) var dockerSocketEnabled = UserDefaults.standard.bool(forKey: "dockerSocketEnabled")

    public func setDockerSocketEnabled(_ enabled: Bool) {
        guard enabled != dockerSocketEnabled else { return }
        dockerSocketEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "dockerSocketEnabled")
        let configuration = Self.agentConfiguration()
        Task { await agent?.updateConfiguration(configuration) }
    }

    /// The socket as the agent reports it; nil without an agent.
    public func dockerSocketStatus() async -> DockerSocketStatus? {
        guard let agent else { return nil }
        return try? await agent.dockerStatus()
    }

    // MARK: - Background agent

    /// Move state to the background agent (polling continues with the window
    /// closed); stay on the local store if it isn't available.
    private func connectAgent() async {
        guard backgroundAgentEnabled else {
            agentStatus = String(localized: "Off — state is polled only while the app runs.")
            return
        }
        let client = await agentConnector.connect(configuration: Self.agentConfiguration())
        agentStatus = agentConnector.statusDescription
        guard let client else { return }
        client.onDisconnect = { [weak self] in
            Task { @MainActor in await self?.agentLost(client) }
        }
        agent = client
        notifier.onOpen = { [weak self] name in
            guard let self else { return }
            section = .containers
            revealContainer = name
            mainWindowRequest += 1
        }
        notifier.onShowLogs = { [weak self] name in
            self?.openContainer(name, tab: .logs)
            self?.mainWindowRequest += 1
        }
        notifier.onMoreMemory = { [weak self] name in
            Task { await self?.giveMoreMemory(name) }
        }
        notifier.onHealth = { [weak self] statuses in
            guard let self else { return }
            model.record(ActivityEntry.health(old: health, new: statuses))
            health = statuses
        }
        notifier.start(agent: client)
        await model.setSource(client, agentBacked: true)
        await localStore.stopPolling()
    }

    private func agentLost(_ client: AgentClient) async {
        guard agent === client else { return }
        notifier.stop()
        health = [:]
        Logger(subsystem: "com.irekobox.app", category: "agent")
            .info("agent lost; falling back to the in-process store")
        agent = nil
        await localStore.startPolling()
        await model.setSource(localStore, agentBacked: false)
    }

    public func setBackgroundAgentEnabled(_ enabled: Bool) {
        guard enabled != backgroundAgentEnabled else { return }
        backgroundAgentEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "backgroundAgentEnabled")
        Task {
            if enabled {
                await connectAgent()
            } else {
                let client = agent
                agent = nil
                client?.disconnect()
                await localStore.startPolling()
                await model.setSource(localStore, agentBacked: false)
                await agentConnector.disable()
                agentStatus = agentConnector.statusDescription
            }
        }
    }

    /// Let the agent drop this client's interests promptly on quit.
    public func disconnectAgent() {
        agent?.disconnect()
    }

    // MARK: - Window visibility

    /// Poll slower while none of the app's windows is visible. Visibility, not
    /// activation, is what counts: a window watched on a second display while
    /// typing in Terminal must stay live.
    private func observeWindowVisibility() {
        let center = NotificationCenter.default
        let update: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                let visible = NSApplication.shared.windows.contains {
                    $0.isVisible && $0.occlusionState.contains(.visible)
                }
                await self?.model.setVisible(visible)
            }
        }
        activityObservers = [
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil,
                               queue: .main, using: update),
            center.addObserver(forName: NSApplication.didHideNotification, object: nil,
                               queue: .main, using: update),
            center.addObserver(forName: NSApplication.didUnhideNotification, object: nil,
                               queue: .main, using: update),
            center.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.disconnectAgent() }
            },
        ]
    }

    // MARK: - Configuration

    /// Rebuild the engine — call after the binary path or polling interval changes.
    public func reconfigure() {
        let path = Settings.shared.binaryPath
        let cli = ContainerCLI(binaryPath: path)
        let engine = PortCheck.guarding(XPCEngine(fallback: CLIEngine(cli: cli, stream: CLIStream(binaryPath: path))))
        self.cli = cli
        self.engine = engine
        self.composeRunner = ComposeRunner(runner: cli)
        engineGeneration &+= 1
        let store = localStore
        let intervals = Self.intervals()
        let agent = self.agent
        let configuration = Self.agentConfiguration()
        Task {
            await store.setIntervals(intervals)
            await store.replaceEngine(engine)
            await agent?.updateConfiguration(configuration)
        }
    }

    /// Apply a changed polling interval.
    public func applyPollingInterval() {
        let store = localStore
        let intervals = Self.intervals()
        let agent = self.agent
        let configuration = Self.agentConfiguration()
        Task {
            await store.setIntervals(intervals)
            await agent?.updateConfiguration(configuration)
        }
    }

    /// Refresh everything visible (and service status). Services ▸ Refresh / ⌘R.
    public func requestRefresh() {
        refreshTick &+= 1
        let model = self.model
        Task { await model.refresh(await model.polledResources()) }
    }

    /// Run a user action. A failure is shown as a toast rather than dropped;
    /// either way `resources` are refreshed so the UI shows the real outcome.
    func perform(refreshing resources: Set<EngineResource> = [.containers],
                 _ action: () async throws -> Void) async {
        do {
            try await action()
        } catch {
            actionError = error.localizedDescription
        }
        if !resources.isEmpty { await model.refresh(resources) }
    }

    /// Refresh the service gate, builder and disk usage now.
    public func refreshSystem() async {
        await model.refresh([.system])
        if servicesRunning { await model.refresh([.diskUsage]) }
    }

    public func startServices() async {
        do {
            try await engine.startServices()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refreshSystem()
    }

    public func stopServices() async {
        UserDefaults.standard.set(true, forKey: Self.stoppedByUserKey)
        do {
            try await engine.stopServices()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refreshSystem()
    }
}

/// A request to show the Run sheet.
struct RunRequest: Identifiable {
    let id = UUID()
    var configuration: RunConfiguration
    /// Open on "Paste docker run".
    var paste = false
}

extension AppState {
    static let stoppedByUserKey = "engineStoppedByUser"

    /// Remember what runs, so a stopped engine can say what's waiting; and
    /// whether the last stop was the user's.
    func rememberWhatRuns() {
        guard servicesRunning else { return }
        let containers = model.containers.filter { !$0.isSystem }
        UserDefaults.standard.set(containers.count, forKey: "lastKnownContainers")
        UserDefaults.standard.set(model.containers.filter(\.isMachine).count, forKey: "lastKnownMachines")
        UserDefaults.standard.set(false, forKey: Self.stoppedByUserKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastSeenRunning")
    }

    /// A project's services as log sources, labelled by service.
    func projectLogs(_ project: String) -> LogsTarget {
        let containers = model.containers.filter { ContainerList.project(of: $0) == project }
            .sorted { $0.serviceName < $1.serviceName }
        let services = Dictionary(grouping: containers, by: \.serviceName)
        let sources = containers.map { container in
            LogsTarget.Source(label: services[container.serviceName, default: []].count > 1 ? container.id : container.serviceName,
                              id: container.id)
        }
        return LogsTarget(title: project, sources: sources)
    }

    /// irekobox://overview, irekobox://project/<name>, irekobox://container/<id>.
    public func open(_ url: URL) {
        guard url.scheme == "irekobox" else { return }
        let name = url.pathComponents.dropFirst().first
        switch url.host() {
        case "project":
            section = .compose
            revealProject = name
        case "logs":
            if let name { windowRequest = .logs(projectLogs(name)) }
        case "compose":
            if let name { windowRequest = .composeFile(name) }
        case "container":
            if let name { openContainer(name) }
        default:
            section = .overview
        }
    }

    /// What the widgets show, from the polled state and the stats recorder.
    func writeWidgetSnapshot() {
        let containers = model.containers.filter { !$0.isSystem }
        let running = containers.filter { $0.state.isRunning }
        // Total CPU per sample time, across running containers (last 30 samples).
        let histories = running.compactMap { statsRecorder.histories[$0.id]?.points.suffix(30) }
        let length = histories.map(\.count).max() ?? 0
        let cpu = (0..<length).map { index in
            histories.reduce(0.0) { total, points in
                let offset = length - points.count
                return index >= offset ? total + points[points.startIndex + index - offset].cpuPercent : total
            }
        }
        let memory = running.compactMap { statsRecorder.histories[$0.id]?.points.last?.memoryBytes }.reduce(0, +)
        let usage = model.snapshot.diskUsage.value
        let reclaimable = usage.map { $0.images.reclaimableInBytes + $0.containers.reclaimableInBytes + $0.volumes.reclaimableInBytes } ?? 0
        let projects = ContainerList.group(containers).compactMap { group -> WidgetSnapshot.Project? in
            guard let name = group.project else { return nil }
            let up = group.containers.filter { $0.state.isRunning }
            let healthy = up.allSatisfy { health[$0.id] != "unhealthy" }
            let port = up.lazy.flatMap { $0.configuration.publishedPorts ?? [] }.first?.hostPort
            return WidgetSnapshot.Project(name: name, running: up.count, total: group.containers.count, healthy: healthy, port: port)
        }
        let snapshot = WidgetSnapshot(engineRunning: servicesRunning, running: running.count, total: containers.count,
                                      cpuHistory: cpu, memoryBytes: memory, reclaimableBytes: reclaimable, projects: projects)
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }

    /// Recreate `name` with twice its memory (at most 16 GB), after it ran out.
    func giveMoreMemory(_ name: String) async {
        await perform {
            let container = try await engine.inspectContainer(name)
            var edits = ContainerRecreate.currentEdits(for: container)
            let current = max(64, container.configuration.resources.memoryInBytes / (1024 * 1024))
            edits.memoryMiB = min(16 * 1024, current * 2)
            try await engine.recreateContainer(container, edits: edits)
        }
    }

    /// The MCP server asks before an assistant deletes something.
    func listenForAssistantApprovals() {
        let notifier = self.notifier
        DistributedNotificationCenter.default().addObserver(forName: AppApprover.request, object: nil, queue: .main) { note in
            guard let id = note.object as? String else { return }
            let assistant = note.userInfo?["assistant"] as? String ?? String(localized: "An assistant")
            let action = note.userInfo?["action"] as? String ?? String(localized: "delete something")
            MainActor.assumeIsolated { notifier.askApproval(id: id, assistant: assistant, action: action) }
        }
    }

    /// Deep links from the command line, for screenshots and support:
    /// `-openLink irekobox://…`, `-revealProject shop`, `-revealCluster dev`, `-openContainer web [-containerTab logs]`.
    /// Read from the arguments only, never from saved defaults.
    func openFromLaunchArguments() {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        // -openLink irekobox://logs/shop: once containers are known.
        if let link = (arguments["openLink"] as? String).flatMap(URL.init(string:)) {
            Task { @MainActor in
                for _ in 0..<30 where model.containers.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
                try? await Task.sleep(for: .seconds(1))
                open(link)
            }
        }
        if arguments["openSettings"] != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                settingsRequest += 1
            }
        }
        if let project = arguments["revealProject"] as? String {
            section = .compose
            revealProject = project
        } else if let cluster = arguments["revealCluster"] as? String {
            section = .kubernetes
            revealCluster = cluster
        } else if let volume = arguments["browseVolume"] as? String {
            section = .volumes
            browseVolume = volume
        } else if let id = arguments["openContainer"] as? String {
            let tab = (arguments["containerTab"] as? String).flatMap(ContainerDetailView.DetailTab.init(rawValue:)) ?? .overview
            openContainer(id, tab: tab)
        }
    }
}

/// Which container page to open, and on which tab.
struct ContainerPageRequest: Equatable {
    let id: String
    let tab: ContainerDetailView.DetailTab
}

enum WindowRequest: Equatable {
    case logs(LogsTarget)
    case composeFile(String)
}
