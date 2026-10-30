import Foundation

/// Output of `container system status --format json` (nested shape since CLI 1.4.1).
public struct SystemStatus: Codable, Hashable, Sendable {
    public let status: String
    public let client: Component?
    public let server: Component?
    public let host: Host?
    public let paths: Paths?
    public let resources: Resources?

    public struct Component: Codable, Hashable, Sendable {
        public let appName: String?
        public let version: String?
        public let build: String?
        public let commit: String?
    }

    public struct Host: Codable, Hashable, Sendable {
        public let architecture: String?
        public let cpus: Int?
        public let operatingSystem: String?
    }

    public struct Paths: Codable, Hashable, Sendable {
        public let appRoot: String?
        public let installRoot: String?
        public let logRoot: String?
    }

    public struct Resources: Codable, Hashable, Sendable {
        public let containersRunning: Int?
        public let containersTotal: Int?
        public let images: Int?
    }

    public var isRunning: Bool { status.lowercased() == "running" }

    public var apiServerVersion: String? { server?.version }
    public var apiServerAppName: String? { server?.appName }
    public var clientVersion: String? { client?.version }
    public var appRoot: String? { paths?.appRoot }
    public var installRoot: String? { paths?.installRoot }
    public var hostCPUs: Int? { host?.cpus }
    public var containersRunning: Int? { resources?.containersRunning }
}

/// Output of `container system df --format json` — disk usage per resource type.
public struct SystemDiskUsage: Codable, Hashable, Sendable {
    public let containers: Entry
    public let images: Entry
    public let volumes: Entry

    public struct Entry: Codable, Hashable, Sendable {
        public let total: Int
        public let active: Int
        public let sizeInBytes: Int64
        public let reclaimableInBytes: Int64

        enum CodingKeys: String, CodingKey {
            case total, active, sizeInBytes
            case reclaimableInBytes = "reclaimable"
        }
    }
}
