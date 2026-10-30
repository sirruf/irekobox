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
        /// Labels as stored; `labels` reads values encoded by ``LabelValue``.
        private let rawLabels: [String: String]?
        public var labels: [String: String]? { rawLabels?.mapValues(LabelValue.decode) }
        public let creationDate: String?
        public let options: [String: String]?

        enum CodingKeys: String, CodingKey {
            case name, driver, format, source, sizeInBytes, rawLabels = "labels", creationDate, options
        }
    }

    public var name: String { configuration.name }
    public var source: String? { configuration.source }
    public var driver: String { configuration.driver }
}
