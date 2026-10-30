import Foundation

/// A network from `container network ls/inspect --format json`.
public struct Network: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let configuration: Configuration
    public let status: Status?

    public struct Configuration: Codable, Hashable, Sendable {
        public let name: String
        public let mode: String?
        public let plugin: String?
        public let creationDate: String?
        /// Labels as stored; `labels` reads values encoded by ``LabelValue``.
        private let rawLabels: [String: String]?
        public var labels: [String: String]? { rawLabels?.mapValues(LabelValue.decode) }
        public let options: [String: String]?

        enum CodingKeys: String, CodingKey {
            case name, mode, plugin, creationDate, rawLabels = "labels", options
        }
    }

    public struct Status: Codable, Hashable, Sendable {
        public let ipv4Gateway: String?
        public let ipv4Subnet: String?
        public let ipv6Subnet: String?
    }

    public var name: String { configuration.name }
    public var mode: String? { configuration.mode }
    public var subnet: String? { status?.ipv4Subnet }
    public var gateway: String? { status?.ipv4Gateway }
    /// Built-in networks (e.g. `default`) shouldn't be deletable in the UI.
    public var isBuiltin: Bool {
        configuration.labels?["com.apple.container.resource.role"] == "builtin"
    }
}
