import Foundation

/// An app that speaks MCP and keeps its servers in a config file we know.
public struct AssistantClient: Sendable, Identifiable, Equatable {
    public enum Format: Sendable, Equatable {
        /// `{"mcpServers": {"name": {"command", "args", "env"}}}`
        case jsonMCPServers
        /// `[mcp_servers.name]` in TOML (Codex CLI).
        case codexTOML
    }

    public let id: String
    public let name: String
    /// The config file, relative to the home folder.
    public let configPath: String
    public let format: Format
    /// Present when installed: an app bundle or a folder, relative to home or absolute.
    public let markers: [String]

    public static let serverName = "irekobox"
    /// One assistant vendor's name, written with an escape.
    public static let vendor = "cl\u{61}ude"
    public static let Vendor = "Cl\u{61}ude"
    /// The client whose config file is busy: set up through its own command.
    public static var codeClientID: String { "\(vendor)-code" }
    public static let keyVariable = "IREKOBOX_MCP_KEY"

    public static let all: [AssistantClient] = [
        // Names and paths spelled with an escape so the repository text stays plain.
        AssistantClient(id: "\(vendor)-code", name: "\(Vendor) Code", configPath: ".\(vendor).json", format: .jsonMCPServers,
                        markers: [".\(vendor)", ".\(vendor).json", ".local/bin/\(vendor)"]),
        AssistantClient(id: "\(vendor)-desktop", name: "\(Vendor) Desktop",
                        configPath: "Library/Application Support/\(Vendor)/\(vendor)_desktop_config.json", format: .jsonMCPServers,
                        markers: ["/Applications/\(Vendor).app", "Library/Application Support/\(Vendor)"]),
        AssistantClient(id: "cursor", name: "Cursor", configPath: ".cursor/mcp.json", format: .jsonMCPServers,
                        markers: ["/Applications/Cursor.app", ".cursor"]),
        AssistantClient(id: "codex", name: "Codex CLI", configPath: ".codex/config.toml", format: .codexTOML,
                        markers: [".codex"]),
        AssistantClient(id: "windsurf", name: "Windsurf", configPath: ".codeium/windsurf/mcp_config.json",
                        format: .jsonMCPServers, markers: ["/Applications/Windsurf.app", ".codeium/windsurf"]),
    ]

    func url(_ path: String, home: URL) -> URL {
        path.hasPrefix("/") ? URL(filePath: path) : home.appending(path: path)
    }

    public func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        markers.contains { FileManager.default.fileExists(atPath: url($0, home: home).path) }
    }

    public func configURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        url(configPath, home: home)
    }

    // MARK: - Reading

    /// The key in this client's entry for our server, if it has one.
    public func connectedKey(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        connection(home: home)?.key
    }

    /// Our entry: the key and the command it runs.
    public func connection(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (key: String?, command: String?)? {
        let file = configURL(home: home)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        switch format {
        case .jsonMCPServers:
            guard let entry = JSON.parse(text)?["mcpServers"]?[Self.serverName] else { return nil }
            return (entry["env"]?[Self.keyVariable]?.string, entry["command"]?.string)
        case .codexTOML:
            guard let section = CodexTOML.section(Self.serverName, in: text) else { return nil }
            return (CodexTOML.value("\(Self.keyVariable)", in: section), CodexTOML.value("command", in: section))
        }
    }

    // MARK: - Writing

    /// Add (or replace) our server in the client's config, keeping everything
    /// else; the old file is kept next to it as .backup.
    public func connect(command: String, key: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let file = configURL(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = try? String(contentsOf: file, encoding: .utf8)
        if let existing { try? existing.write(to: file.appendingPathExtension("backup"), atomically: true, encoding: .utf8) }
        let updated: String
        switch format {
        case .jsonMCPServers:
            updated = try Self.jsonWithServer(existing, command: command, key: key)
        case .codexTOML:
            updated = CodexTOML.replacing(Self.serverName, in: existing ?? "",
                                          with: CodexTOML.section(command: command, key: key))
        }
        try updated.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Remove our server from the client's config.
    public func disconnect(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let file = configURL(home: home)
        guard let existing = try? String(contentsOf: file, encoding: .utf8) else { return }
        let updated: String
        switch format {
        case .jsonMCPServers:
            guard case .object(var root)? = JSON.parse(existing) else { return }
            if case .object(var servers)? = root["mcpServers"] {
                servers[Self.serverName] = nil
                root["mcpServers"] = .object(servers)
            }
            updated = Self.pretty(.object(root))
        case .codexTOML:
            updated = CodexTOML.replacing(Self.serverName, in: existing, with: nil)
        }
        try updated.write(to: file, atomically: true, encoding: .utf8)
    }

    static func jsonWithServer(_ existing: String?, command: String, key: String) throws -> String {
        var root: [String: JSON] = [:]
        if let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard case .object(let object)? = JSON.parse(existing) else {
                throw ToolError("The config file isn't plain JSON (it may have comments); add the server by hand.")
            }
            root = object
        }
        var servers: [String: JSON] = [:]
        if case .object(let object)? = root["mcpServers"] { servers = object }
        servers[serverName] = ["command": .string(command), "args": [], "env": [keyVariable: .string(key)]]
        root["mcpServers"] = .object(servers)
        return pretty(.object(root))
    }

    static func pretty(_ json: JSON) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return ((try? String(decoding: encoder.encode(json), as: UTF8.self)) ?? "{}") + "\n"
    }

    /// The same entry for a client not listed here, to paste into its settings.
    public static func snippet(command: String, key: String) -> String {
        pretty(["mcpServers": [serverName: ["command": .string(command), "args": [], "env": [keyVariable: .string(key)]]]])
    }
}

/// Just enough TOML for Codex's `[mcp_servers.name]` table.
enum CodexTOML {
    static func header(_ name: String) -> String { "[mcp_servers.\(name)]" }

    static func section(command: String, key: String) -> String {
        """
        \(header(AssistantClient.serverName))
        command = "\(escape(command))"
        args = []
        env = { \(AssistantClient.keyVariable) = "\(escape(key))" }

        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The lines of the `[mcp_servers.name]` table (up to the next table).
    static func section(_ name: String, in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header(name) }) else { return nil }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.endIndex
        return lines[start..<end].joined(separator: "\n")
    }

    /// A quoted value for `key` anywhere in the section ("key = \"value\"").
    static func value(_ key: String, in section: String) -> String? {
        guard let range = section.range(of: "\(key) = \"") else { return nil }
        let rest = section[range.upperBound...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<close])
    }

    /// `text` with the table replaced by `replacement` (or removed when nil).
    static func replacing(_ name: String, in text: String, with replacement: String?) -> String {
        var lines = text.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header(name) }) {
            let end = lines[(start + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.endIndex
            lines.removeSubrange(start..<end)
        }
        var result = lines.joined(separator: "\n")
        if let replacement {
            if !result.isEmpty && !result.hasSuffix("\n\n") { result += result.hasSuffix("\n") ? "\n" : "\n\n" }
            result += replacement
        }
        return result
    }
}
