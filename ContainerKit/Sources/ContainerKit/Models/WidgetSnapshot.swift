import Foundation

/// What the widgets and the Control Center control show: written by the app
/// into the shared app-group folder, read by the widget extension.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public struct Project: Codable, Sendable, Equatable, Identifiable {
        public let name: String
        public let running: Int
        public let total: Int
        /// Every running service passes its health check (or has none).
        public let healthy: Bool
        /// The first port open on this Mac (":8080"), if any.
        public let port: Int?
        public var id: String { name }

        public init(name: String, running: Int, total: Int, healthy: Bool, port: Int?) {
            self.name = name
            self.running = running
            self.total = total
            self.healthy = healthy
            self.port = port
        }
    }

    public var updated: Date
    public var engineRunning: Bool
    public var running: Int
    public var total: Int
    /// Total CPU of running containers, % of one core, oldest first.
    public var cpuHistory: [Double]
    public var memoryBytes: Int64
    public var reclaimableBytes: Int64
    public var projects: [Project]

    public init(updated: Date = Date(), engineRunning: Bool = false, running: Int = 0, total: Int = 0,
                cpuHistory: [Double] = [], memoryBytes: Int64 = 0, reclaimableBytes: Int64 = 0, projects: [Project] = []) {
        self.updated = updated
        self.engineRunning = engineRunning
        self.running = running
        self.total = total
        self.cpuHistory = cpuHistory
        self.memoryBytes = memoryBytes
        self.reclaimableBytes = reclaimableBytes
        self.projects = projects
    }

    public static let appGroup = "YBKR9G3374.com.irekobox.shared"

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "widget-snapshot.json")
    }

    public static func load() -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    public func save() {
        guard let url = Self.url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(self).write(to: url, options: .atomic)
    }
}
