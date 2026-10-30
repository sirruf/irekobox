import Foundation

/// A container as reported by `container list --format json` / `container inspect`.
///
/// Field shapes were captured from the live CLI 1.6.1. `list` and `inspect`
/// return the same object, so a single model serves both.
public struct Container: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let status: Status
    public let configuration: Configuration

    public struct Status: Codable, Hashable, Sendable {
        public let state: State
        public let networks: [RuntimeNetwork]
        /// ISO-8601; present only while running.
        public let startedDate: String?
    }

    /// Lifecycle state. Unknown raw values decode to `.unknown` rather than failing.
    public enum State: Hashable, Sendable {
        case running
        case stopped
        case stopping
        case unknown(String)

        public var rawValue: String {
            switch self {
            case .running: return "running"
            case .stopped: return "stopped"
            case .stopping: return "stopping"
            case .unknown(let value): return value
            }
        }

        public var isRunning: Bool { self == .running }
    }

    /// Runtime network attachment (populated only while running).
    public struct RuntimeNetwork: Codable, Hashable, Sendable {
        public let network: String?
        public let hostname: String?
        /// CIDR form, e.g. `192.168.66.2/24`.
        public let ipv4Address: String?
        public let ipv4Gateway: String?
        public let ipv6Address: String?
        public let macAddress: String?
        public let mtu: Int?
    }

    public struct Configuration: Codable, Hashable, Sendable {
        public let id: String
        public let image: ImageRef
        public let resources: Resources
        public let platform: Platform
        public let networks: [ConfiguredNetwork]
        public let initProcess: InitProcess
        public let labels: [String: String]
        public let creationDate: String
        public let readOnly: Bool
        public let runtimeHandler: String
        public let rosetta: Bool
        public let publishedPorts: [PublishedPort]?
        public let mounts: [Mount]?
    }

    /// A published port from `inspect` (`publishedPorts`).
    public struct PublishedPort: Codable, Hashable, Sendable {
        public let containerPort: Int
        public let hostPort: Int
        public let hostAddress: String?
        public let proto: String?
        /// Number of consecutive ports in the range starting at the given ports.
        public let count: Int?

        public init(containerPort: Int, hostPort: Int, hostAddress: String? = nil,
                    proto: String? = "tcp", count: Int? = 1) {
            self.containerPort = containerPort
            self.hostPort = hostPort
            self.hostAddress = hostAddress
            self.proto = proto
            self.count = count
        }

        /// `[host-ip:]host:container[/proto]` for `--publish`.
        public var runSpec: String {
            var spec = ""
            if let hostAddress, hostAddress != "0.0.0.0" { spec += "\(hostAddress):" }
            spec += "\(hostPort):\(containerPort)"
            if let proto, proto.lowercased() != "tcp" { spec += "/\(proto)" }
            return spec
        }
    }

    /// A mount from `inspect` (`mounts`): named volume (`type.volume.name`) or bind.
    public struct Mount: Codable, Hashable, Sendable {
        public let destination: String
        public let source: String?
        public let options: [String]?
        public let type: TypeBox?

        public struct TypeBox: Codable, Hashable, Sendable {
            public let volume: VolumeType?
            public struct VolumeType: Codable, Hashable, Sendable {
                public let name: String?
            }
        }

        public var volumeName: String? { type?.volume?.name }
        public var isReadOnly: Bool { options?.contains("ro") ?? false }

        /// `source:destination[:ro]` for `--volume` (named volume → its name).
        public var runSpec: String? {
            guard let src = volumeName ?? source else { return nil }
            return src + ":" + destination + (isReadOnly ? ":ro" : "")
        }
    }

    public struct ImageRef: Codable, Hashable, Sendable {
        public let reference: String
        public let descriptor: Descriptor

        public struct Descriptor: Codable, Hashable, Sendable {
            public let digest: String
            public let mediaType: String
            public let size: Int
        }
    }

    public struct Resources: Codable, Hashable, Sendable {
        public let cpus: Int
        public let memoryInBytes: Int64
        public let cpuOverhead: Int?
    }

    public struct Platform: Codable, Hashable, Sendable {
        public let architecture: String
        public let os: String
    }

    public struct ConfiguredNetwork: Codable, Hashable, Sendable {
        public let network: String
        public let options: Options?

        public struct Options: Codable, Hashable, Sendable {
            public let hostname: String?
            public let mtu: Int?
            public let aliases: [String]?
        }
    }

    public struct InitProcess: Codable, Hashable, Sendable {
        public let executable: String
        public let arguments: [String]
        public let workingDirectory: String
        public let environment: [String]
        /// Started with a TTY (`-t`).
        public let terminal: Bool?
        /// Who the process runs as; exec inherits it.
        public let user: ProcessSpec.User?
    }
}

// MARK: - Convenience accessors for the UI

public extension Container {
    /// `docker.io/library/alpine:latest` → `alpine:latest`.
    var imageShortName: String {
        let reference = configuration.image.reference
        guard let last = reference.split(separator: "/").last else { return reference }
        return String(last)
    }

    var state: State { status.state }

    var memoryInBytes: Int64 { configuration.resources.memoryInBytes }

    var cpus: Int { configuration.resources.cpus }

    /// Containers managed by `container` itself: the BuildKit `buildkit`
    /// builder (a `com.apple.container.resource.role` label) and the
    /// containers that run container machines (shown as machines instead),
    /// and Irekobox's own short-lived helpers (volume backups and browsing).
    var isSystem: Bool {
        configuration.labels["com.apple.container.resource.role"] != nil || isMachine
            || configuration.labels["com.irekobox.helper"] != nil
    }

    /// Runs a container machine (`container machine`).
    public var isMachine: Bool { configuration.labels["com.apple.container.plugin"] == "machine" }

    /// The machine's name (`ubuntu-24-04` for `ubuntu-24-04-e9db04`), from
    /// its hostname `ubuntu-24-04.machine.`.
    public var machineName: String? {
        guard isMachine else { return nil }
        if let hostname = configuration.networks.first?.options?.hostname, hostname.hasSuffix(".machine.") {
            return String(hostname.dropLast(".machine.".count))
        }
        guard let dash = id.lastIndex(of: "-") else { return id }
        return String(id[..<dash])
    }

    /// First IPv4 address without the prefix length; `nil` when not running.
    var ipv4Address: String? {
        guard let cidr = status.networks.first?.ipv4Address else { return nil }
        return String(cidr.split(separator: "/").first ?? Substring(cidr))
    }

    /// When the container was started; `nil` when not running.
    var startedDate: Date? {
        status.startedDate.flatMap { try? Date($0, strategy: .iso8601) }
    }
}

// MARK: - State decoding with unknown fallback

extension Container.State: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw.lowercased() {
        case "running": self = .running
        case "stopped": self = .stopped
        case "stopping": self = .stopping
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
