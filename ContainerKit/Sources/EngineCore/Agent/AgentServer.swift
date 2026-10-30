import Foundation
import ContainerKit

/// Hosts an ``EngineStore`` behind the ``AgentServiceProtocol`` XPC interface.
///
/// Each client connection owns its interests and window visibility; both are
/// dropped when the connection goes away, so a crashed app can't pin polling.
public final class AgentServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let store: EngineStore
    private let listener: NSXPCListener
    /// Builds the engine for a configured `container` binary path.
    private let makeEngine: @Sendable (String) -> any ContainerEngine
    private let lock = NSLock()
    private var visibleClients: Set<ObjectIdentifier> = []
    private var configuration: AgentConfiguration?
    /// Called by ``AgentServiceProtocol/restart()``; defaults to exiting.
    var onRestart: @Sendable () -> Void = { exit(0) }
    /// Where the last configuration is kept (nil in tests).
    private let configurationFile: URL?
    /// Told about every configuration, including the saved one at launch
    /// (the agent's host starts or stops the Docker socket here).
    public var onConfigure: (@Sendable (AgentConfiguration) async -> Void)?
    /// Answers ``AgentServiceProtocol/dockerStatus(reply:)``.
    public var dockerStatus: (@Sendable () async -> DockerSocketStatus)?
    /// Receives ``AgentServiceProtocol/handAction(stopped:names:)``.
    public var onHandAction: (@Sendable (_ stopped: Bool, _ names: [String]) async -> Void)?
    /// Answers ``AgentServiceProtocol/alerts(after:reply:)``: alerts and the latest sequence.
    public var alerts: (@Sendable (UInt64) async -> ([ContainerAlert], UInt64))?
    /// Answers ``AgentServiceProtocol/healthStatuses(reply:)``.
    public var healthStatuses: (@Sendable () async -> [String: String])?
    /// Called once with the configuration saved before this launch (none on
    /// a first run): the time to start the engine at login.
    public var onLaunch: (@Sendable (AgentConfiguration?) async -> Void)?

    /// `~/Library/Application Support/Irekobox/agent-configuration.json`.
    public static var defaultConfigurationFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Irekobox/agent-configuration.json")
    }

    /// Serve on the agent's Mach service; only team-signed clients may connect.
    public convenience init(machServiceName: String = AgentConstants.machServiceName) {
        let listener = NSXPCListener(machServiceName: machServiceName)
        listener.setConnectionCodeSigningRequirement(AgentConstants.clientRequirement)
        self.init(listener: listener, engine: CLIEngine(), configurationFile: Self.defaultConfigurationFile) { path in
            XPCEngine(fallback: CLIEngine(cli: ContainerCLI(binaryPath: path), stream: CLIStream(binaryPath: path)))
        }
    }

    /// Serve on `listener` (tests use an anonymous listener).
    init(listener: NSXPCListener, engine: any ContainerEngine,
         intervals: EngineStore.Intervals = EngineStore.Intervals(),
         configurationFile: URL? = nil,
         makeEngine: @escaping @Sendable (String) -> any ContainerEngine) {
        self.listener = listener
        self.makeEngine = makeEngine
        self.configurationFile = configurationFile
        self.store = EngineStore(engine: engine, intervals: intervals)
        super.init()
        listener.delegate = self
    }

    public func resume() {
        _ = AgentInfo.current   // pin the launch-time identity
        let store = self.store
        let saved = configurationFile.flatMap { try? Data(contentsOf: $0) }
            .flatMap { AgentJSON.decode(AgentConfiguration.self, $0) }
        Task {
            await store.setBackground(true)   // until a client shows a window
            // Serve what was configured last, before any client connects.
            if let saved { await self.configure(saved, save: false) }
            await self.onLaunch?(saved)
            await store.startPolling()
        }
        listener.resume()
    }

    var endpoint: NSXPCListenerEndpoint { listener.endpoint }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let handler = AgentConnectionHandler(server: self, connection: connection)
        connection.exportedInterface = .agentService
        connection.exportedObject = handler
        connection.remoteObjectInterface = .agentClient
        connection.invalidationHandler = { [weak handler] in handler?.connectionEnded() }
        connection.interruptionHandler = { [weak handler] in handler?.connectionEnded() }
        connection.resume()
        return true
    }

    // MARK: - Shared state

    func configure(_ configuration: AgentConfiguration, save: Bool = true) async {
        if save, let configurationFile {
            try? FileManager.default.createDirectory(at: configurationFile.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? AgentJSON.encode(configuration).write(to: configurationFile, options: .atomic)
        }
        await onConfigure?(configuration)
        let changed = lock.withLock { () -> (engine: Bool, intervals: Bool) in
            defer { self.configuration = configuration }
            return (self.configuration?.binaryPath != configuration.binaryPath,
                    self.configuration?.containersIntervalMilliseconds != configuration.containersIntervalMilliseconds)
        }
        if changed.intervals {
            await store.setIntervals(EngineStore.Intervals(
                containers: .milliseconds(configuration.containersIntervalMilliseconds)))
        }
        if changed.engine {
            await store.replaceEngine(makeEngine(configuration.binaryPath))
        }
    }

    func setVisible(_ visible: Bool, client: ObjectIdentifier) async {
        let anyVisible = lock.withLock { () -> Bool in
            if visible { visibleClients.insert(client) } else { visibleClients.remove(client) }
            return !visibleClients.isEmpty
        }
        await store.setBackground(!anyVisible)
    }

    func restart() {
        onRestart()
    }

    func currentDockerStatus() async -> DockerSocketStatus {
        if let dockerStatus { return await dockerStatus() }
        let enabled = lock.withLock { configuration?.dockerSocketEnabled ?? false }
        return DockerSocketStatus(enabled: enabled, listening: false, socketPath: DockerSocketStatus.defaultPath,
                                  error: enabled ? "This agent has no Docker API." : nil)
    }
}

/// One client connection: its interests, visibility, and update push.
final class AgentConnectionHandler: NSObject, AgentServiceProtocol, @unchecked Sendable {
    private weak var server: AgentServer?
    private weak var connection: NSXPCConnection?
    private let lock = NSLock()
    private var tokens: [String: UUID] = [:]
    private var pushTask: Task<Void, Never>?
    private var ended = false

    init(server: AgentServer, connection: NSXPCConnection) {
        self.server = server
        self.connection = connection
    }

    private var store: EngineStore? { server?.store }

    func hello(reply: @escaping @Sendable (Data) -> Void) {
        reply(AgentJSON.encode(AgentInfo.current))
    }

    func handAction(stopped: Bool, names: Data) {
        guard let server, let list = AgentJSON.decode([String].self, names) else { return }
        Task { await server.onHandAction?(stopped, list) }
    }

    func alerts(after sequence: UInt64, reply: @escaping @Sendable (Data, UInt64) -> Void) {
        guard let server, let source = server.alerts else { return reply(AgentJSON.encode([ContainerAlert]()), 0) }
        Task {
            let (alerts, latest) = await source(sequence)
            reply(AgentJSON.encode(alerts), latest)
        }
    }

    func healthStatuses(reply: @escaping @Sendable (Data) -> Void) {
        guard let server, let source = server.healthStatuses else { return reply(AgentJSON.encode([String: String]())) }
        Task { reply(AgentJSON.encode(await source())) }
    }

    func dockerStatus(reply: @escaping @Sendable (Data) -> Void) {
        guard let server else { return reply(Data()) }
        Task { reply(AgentJSON.encode(await server.currentDockerStatus())) }
    }

    func configure(_ configuration: Data, reply: @escaping @Sendable () -> Void) {
        guard let server, let configuration = AgentJSON.decode(AgentConfiguration.self, configuration) else {
            return reply()
        }
        Task {
            await server.configure(configuration)
            reply()
        }
    }

    func subscribe(reply: @escaping @Sendable (Data) -> Void) {
        guard let store else { return reply(Data()) }
        let client = ClientProxy(connection?.remoteObjectProxyWithErrorHandler { _ in } as? AgentClientProtocol)
        Task {
            let stream = await store.updates()
            let task = Task {
                // The stream starts with the current snapshot, sent as the reply.
                for await update in stream.dropFirst() {
                    client.proxy?.receive(update: AgentJSON.encode(update))
                }
            }
            reply(AgentJSON.encode(EngineUpdate(snapshot: await store.snapshot, events: [])))
            let alreadyEnded = lock.withLock { () -> Bool in
                pushTask?.cancel()
                pushTask = task
                return ended
            }
            if alreadyEnded { task.cancel() }
        }
    }

    func addInterest(_ resources: Data, reply: @escaping @Sendable (String) -> Void) {
        guard let store, let list = AgentJSON.decode([EngineResource].self, resources) else { return reply("") }
        Task {
            let token = await store.addInterest(Set(list))
            let key = token.uuidString
            let alreadyEnded = lock.withLock { () -> Bool in
                tokens[key] = token
                return ended
            }
            if alreadyEnded { await store.removeInterest(token) }
            reply(key)
        }
    }

    func removeInterest(_ token: String) {
        guard let store, let id = lock.withLock({ tokens.removeValue(forKey: token) }) else { return }
        Task { await store.removeInterest(id) }
    }

    func refresh(_ resources: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let store, let list = AgentJSON.decode([EngineResource].self, resources) else { return reply(Data()) }
        Task { reply(AgentJSON.encode(await store.refreshSnapshot(Set(list)))) }
    }

    func setVisible(_ visible: Bool) {
        guard let server else { return }
        let client = ObjectIdentifier(self)
        Task { await server.setVisible(visible, client: client) }
    }

    func polledResources(reply: @escaping @Sendable (Data) -> Void) {
        guard let store else { return reply(Data()) }
        Task { reply(AgentJSON.encode(Array(await store.polledResources))) }
    }

    func restart() {
        server?.restart()
    }

    /// The client went away: drop its interests, visibility, and update push.
    func connectionEnded() {
        let (ids, task) = lock.withLock { () -> ([UUID], Task<Void, Never>?) in
            ended = true
            defer { tokens = [:]; pushTask = nil }
            return (Array(tokens.values), pushTask)
        }
        task?.cancel()
        guard let server, let store else { return }
        let client = ObjectIdentifier(self)
        Task {
            for id in ids { await store.removeInterest(id) }
            await server.setVisible(false, client: client)
        }
    }
}

/// An NSXPC remote-object proxy, which may be messaged from any thread.
private struct ClientProxy: @unchecked Sendable {
    let proxy: AgentClientProtocol?
    init(_ proxy: AgentClientProtocol?) { self.proxy = proxy }
}
