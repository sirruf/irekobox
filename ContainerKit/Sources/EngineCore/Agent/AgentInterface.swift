import Foundation

/// Constants shared by the background agent and its clients.
public enum AgentConstants {
    /// launchd label and Mach service of the agent.
    public static let machServiceName = "com.irekobox.agent"
    /// File name of the LaunchAgent plist inside `Contents/Library/LaunchAgents`.
    public static let plistName = "com.irekobox.agent.plist"
    /// Bumped on any incompatible change to ``AgentServiceProtocol``.
    public static let protocolVersion = 4
    /// Only processes signed by this team may connect.
    public static let clientRequirement =
        #"anchor apple generic and certificate leaf[subject.OU] = "YBKR9G3374""#
}

/// The agent's XPC interface. Payloads are JSON (`Data`) so the Swift models
/// cross the boundary unchanged.
@objc public protocol AgentServiceProtocol {
    /// ``AgentInfo`` as JSON.
    func hello(reply: @escaping @Sendable (Data) -> Void)
    /// ``AgentConfiguration`` as JSON; applied before replying.
    func configure(_ configuration: Data, reply: @escaping @Sendable () -> Void)
    /// Start pushing ``EngineUpdate``s to the client's exported
    /// ``AgentClientProtocol``; replies with the current update.
    func subscribe(reply: @escaping @Sendable (Data) -> Void)
    /// `[EngineResource]` as JSON; replies with an interest token.
    func addInterest(_ resources: Data, reply: @escaping @Sendable (String) -> Void)
    func removeInterest(_ token: String)
    /// `[EngineResource]` as JSON; replies with the ``EngineSnapshot`` after refreshing.
    func refresh(_ resources: Data, reply: @escaping @Sendable (Data) -> Void)
    func setVisible(_ visible: Bool)
    /// `[EngineResource]` as JSON.
    func polledResources(reply: @escaping @Sendable (Data) -> Void)
    /// Exit so launchd relaunches the agent (e.g. from a newer binary).
    func restart()
    /// ``DockerSocketStatus`` as JSON.
    func dockerStatus(reply: @escaping @Sendable (Data) -> Void)
    /// A user stopped (`stopped` true) or started containers (`[String]` JSON):
    /// a stop by hand must not trigger a restart policy.
    func handAction(stopped: Bool, names: Data)
    /// `[ContainerAlert]` newer than `sequence` as JSON; `latest` is the
    /// newest sequence (start there to skip the past).
    func alerts(after sequence: UInt64, reply: @escaping @Sendable (Data, UInt64) -> Void)
    /// `[String: String]` container name → health status, as JSON.
    func healthStatuses(reply: @escaping @Sendable (Data) -> Void)
}

/// Implemented by clients to receive pushed updates.
@objc public protocol AgentClientProtocol {
    /// ``EngineUpdate`` as JSON.
    func receive(update: Data)
}

/// Who answered: lets a client detect an agent running an outdated binary.
public struct AgentInfo: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let pid: Int32
    public let executablePath: String
    /// Modification time of the running executable when it started.
    public let executableModified: Date?

    /// Captured once, at launch: after a rebuild the file on disk is newer than
    /// the code this process is running, which is exactly what clients detect.
    public static let current: AgentInfo = {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        return AgentInfo(protocolVersion: AgentConstants.protocolVersion,
                         pid: ProcessInfo.processInfo.processIdentifier,
                         executablePath: path, executableModified: modified)
    }()
}

/// Settings a client pushes to the agent. The agent keeps the last one on
/// disk: at login it starts before any client and must know what to serve.
public struct AgentConfiguration: Codable, Sendable, Equatable {
    public var binaryPath: String
    public var containersIntervalMilliseconds: Int
    /// Serve the Docker Engine API on ``DockerSocketStatus/defaultPath``.
    public var dockerSocketEnabled: Bool
    /// Start the `container` services when the agent starts (at login).
    public var startEngineAtLogin: Bool

    public init(binaryPath: String, containersIntervalMilliseconds: Int, dockerSocketEnabled: Bool = false,
                startEngineAtLogin: Bool = false) {
        self.binaryPath = binaryPath
        self.containersIntervalMilliseconds = containersIntervalMilliseconds
        self.dockerSocketEnabled = dockerSocketEnabled
        self.startEngineAtLogin = startEngineAtLogin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        binaryPath = try container.decode(String.self, forKey: .binaryPath)
        containersIntervalMilliseconds = try container.decode(Int.self, forKey: .containersIntervalMilliseconds)
        dockerSocketEnabled = try container.decodeIfPresent(Bool.self, forKey: .dockerSocketEnabled) ?? false
        startEngineAtLogin = try container.decodeIfPresent(Bool.self, forKey: .startEngineAtLogin) ?? false
    }
}

/// The agent's Docker API socket, as Settings shows it.
public struct DockerSocketStatus: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var listening: Bool
    public var socketPath: String
    /// Why it isn't listening although enabled.
    public var error: String?

    public init(enabled: Bool, listening: Bool, socketPath: String, error: String? = nil) {
        self.enabled = enabled
        self.listening = listening
        self.socketPath = socketPath
        self.error = error
    }

    /// `~/.irekobox/docker.sock`.
    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".irekobox/docker.sock").path
    }
}

extension NSXPCInterface {
    static var agentService: NSXPCInterface { NSXPCInterface(with: AgentServiceProtocol.self) }
    static var agentClient: NSXPCInterface { NSXPCInterface(with: AgentClientProtocol.self) }
}

enum AgentJSON {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? encoder.encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
        try? decoder.decode(type, from: data)
    }
}
