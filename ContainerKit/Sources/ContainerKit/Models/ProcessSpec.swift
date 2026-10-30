import Foundation

/// A process to run in a container (apiserver `processConfig`, the shape of
/// apple/container's `ProcessConfiguration`).
public struct ProcessSpec: Codable, Hashable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String]
    public var workingDirectory: String
    public var terminal: Bool
    public var user: User
    public var supplementalGroups: [UInt32]
    public var rlimits: [Rlimit]

    /// `{"id":{"uid":0,"gid":0}}` or `{"raw":{"userString":"app"}}`.
    public enum User: Codable, Hashable, Sendable {
        case raw(userString: String)
        case id(uid: UInt32, gid: UInt32)
    }

    public struct Rlimit: Codable, Hashable, Sendable {
        public let limit: String
        public let soft: UInt64
        public let hard: UInt64
    }

    public init(executable: String, arguments: [String], environment: [String], workingDirectory: String = "/",
                terminal: Bool = false, user: User = .id(uid: 0, gid: 0),
                supplementalGroups: [UInt32] = [], rlimits: [Rlimit] = []) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.terminal = terminal
        self.user = user
        self.supplementalGroups = supplementalGroups
        self.rlimits = rlimits
    }
}

/// File descriptors handed to a process: the apiserver receives duplicates,
/// so the caller closes its own copies after the call.
public struct ProcessStdio: Sendable {
    public var stdin: Int32?
    public var stdout: Int32?
    public var stderr: Int32?

    public init(stdin: Int32? = nil, stdout: Int32? = nil, stderr: Int32? = nil) {
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
    }
}
