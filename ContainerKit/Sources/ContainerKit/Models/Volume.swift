import Foundation

/// A volume from `container volume ls/inspect --format json`.
public struct Volume: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let configuration: Configuration

    public struct Configuration: Codable, Hashable, Sendable {
        public let name: String
        public let driver: String
        public let format: String?
        public let source: String?
        /// Allocated (sparse) size of the volume image.
        public let sizeInBytes: Int64?
        public let labels: [String: String]?
        public let creationDate: String?
        public let options: [String: String]?
    }

    public var name: String { configuration.name }
    public var source: String? { configuration.source }
    public var driver: String { configuration.driver }
}
