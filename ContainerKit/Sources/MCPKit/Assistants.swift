import Foundation

/// What an AI assistant may do through Irekobox's MCP server.
public enum AccessLevel: String, Codable, Sendable, CaseIterable, Comparable {
    /// See containers, logs, stats, images, clusters.
    case lookOnly
    /// Also start, stop, restart, scale and pull.
    case operate
    /// Also create, delete, apply YAML and run commands inside.
    case everything

    public var title: String {
        switch self {
        case .lookOnly: "Look only"
        case .operate: "Look and operate"
        case .everything: "Everything"
        }
    }

    public var summary: String {
        switch self {
        case .lookOnly: "See containers, logs, stats, clusters."
        case .operate: "Also start, stop, restart, scale, pull. No deleting."
        case .everything: "Also create, delete, apply YAML, run commands inside."
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (lhs: AccessLevel, rhs: AccessLevel) -> Bool { lhs.rank < rhs.rank }
}

/// An assistant connected with its own key.
public struct Assistant: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    /// "Cursor", "Codex CLI"…
    public var name: String
    /// Which client it is (`AssistantClient.id`), or "custom".
    public var client: String
    public var key: String
    public var level: AccessLevel
    public var created: Date

    public init(id: String = UUID().uuidString, name: String, client: String, key: String = Assistant.newKey(),
                level: AccessLevel, created: Date = Date()) {
        self.id = id
        self.name = name
        self.client = client
        self.key = key
        self.level = level
        self.created = created
    }

    /// 32 random bytes, hex: unguessable, fine in a config file.
    public static func newKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return "ibx_" + bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// The assistants and the shared rules, in Application Support. Read on every
/// request by the server, so changes in Settings apply at once.
public struct AssistantSettings: Codable, Sendable, Equatable {
    public var assistants: [Assistant] = []
    /// For a client that connects with no key or an unknown one.
    public var newAssistantLevel: AccessLevel = .lookOnly
    /// Deleting asks the person at the Mac first, whichever assistant asks.
    public var askBeforeDeleting = true

    public init() {}

    public func assistant(forKey key: String?) -> Assistant? {
        guard let key, !key.isEmpty else { return nil }
        return assistants.first { $0.key == key }
    }

    public func level(forKey key: String?) -> AccessLevel {
        assistant(forKey: key)?.level ?? newAssistantLevel
    }
}

/// Where the settings and the activity log live.
public enum AssistantFiles {
    public static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Irekobox", directoryHint: .isDirectory)
    }

    public static var settings: URL { folder.appending(path: "assistants.json") }
    public static var activity: URL { folder.appending(path: "assistant-activity.jsonl") }

    public static func load(from url: URL = settings) -> AssistantSettings {
        guard let data = try? Data(contentsOf: url) else { return AssistantSettings() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(AssistantSettings.self, from: data)) ?? AssistantSettings()
    }

    public static func save(_ settings: AssistantSettings, to url: URL = settings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
        // Keys are secrets: only this user reads the file.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// What assistants did, one JSON object per line, newest last.
public struct AssistantActivity: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(date.timeIntervalSince1970)-\(tool)" }
    public let date: Date
    /// The assistant's name, or the client's own name when it has no key.
    public let assistant: String
    public let tool: String
    /// "restarted shop-api-1".
    public let summary: String
    public let outcome: Outcome

    public enum Outcome: String, Codable, Sendable { case done, failed, refused, declined }

    public init(date: Date = Date(), assistant: String, tool: String, summary: String, outcome: Outcome) {
        self.date = date
        self.assistant = assistant
        self.tool = tool
        self.summary = summary
        self.outcome = outcome
    }
}

public enum ActivityLog {
    /// Keep the file small: past this many lines, the oldest go.
    static let limit = 2000

    public static func append(_ entry: AssistantActivity, to url: URL = AssistantFiles.activity) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
        trimIfNeeded(url)
    }

    /// Newest first.
    public static func read(from url: URL = AssistantFiles.activity, limit: Int = 200) -> [AssistantActivity] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").suffix(limit).reversed().compactMap {
            try? decoder.decode(AssistantActivity.self, from: Data($0.utf8))
        }
    }

    private static func trimIfNeeded(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n")
        guard lines.count > limit + limit / 10 else { return }
        try? (lines.suffix(limit).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
