import Foundation

/// `container`'s system configuration: `container system property list`
/// prints the effective values as TOML; overrides live in the user's
/// `~/.config/container/config.toml` and take effect when the engine starts.
///
/// Only the flat `[table]` / `key = value` subset `container` writes is
/// handled: enough to read the listing and change one value without
/// disturbing the rest of the user's file.
enum EngineConfig {
    typealias Tables = [String: [String: String]]

    static var userFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/container/config.toml")
    }

    /// `[container] cpus = 4` → `["container": ["cpus": "4"]]`; string values
    /// lose their quotes.
    static func parse(_ toml: String) -> Tables {
        var tables: Tables = [:]
        var table = ""
        for raw in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                table = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                tables[table, default: [:]] = tables[table] ?? [:]
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            tables[table, default: [:]][key] = value
        }
        return tables
    }

    /// The user's saved values on top of the effective ones: what the engine
    /// will use after its next start.
    static func overlay(_ saved: Tables, on effective: Tables) -> Tables {
        effective.merging(saved) { current, override in current.merging(override) { $1 } }
    }

    /// `toml` with `key` in `[table]` set to `value` (already TOML-formatted,
    /// e.g. `4`, `"2g"`, `true`), or removed when `value` is nil. Comments
    /// and every other line are kept as they were.
    static func setting(_ key: String, in table: String, to value: String?, of toml: String) -> String {
        var lines = toml.isEmpty ? [] : toml.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let header = "[\(table)]"

        func isHeader(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
        }
        func isKey(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "=") else { return false }
            return trimmed[..<equals].trimmingCharacters(in: .whitespaces) == key
        }

        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else {
            guard let value else { return toml }
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines += [header, "\(key) = \(value)"]
            return lines.joined(separator: "\n") + "\n"
        }
        let end = lines[(start + 1)...].firstIndex(where: isHeader) ?? lines.count
        if let existing = lines[(start + 1)..<end].firstIndex(where: isKey) {
            if let value { lines[existing] = "\(key) = \(value)" } else { lines.remove(at: existing) }
        } else if let value {
            // After the table's last key, before any blank lines that separate it.
            var insertAt = end
            while insertAt > start + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt -= 1
            }
            lines.insert("\(key) = \(value)", at: insertAt)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Change one value in the user's file, creating it if needed.
    static func write(_ key: String, in table: String, value: String?, file: URL = userFile) throws {
        let current = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let updated = setting(key, in: table, to: value, of: current)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.write(to: file, atomically: true, encoding: .utf8)
    }

    /// "1gb", "2048mb", "512m" → bytes (binary units, as `container` reads them).
    static func bytes(_ memory: String) -> Int64? {
        let lower = memory.lowercased().trimmingCharacters(in: .whitespaces)
        let digits = lower.prefix { $0.isNumber }
        guard let number = Int64(digits) else { return nil }
        switch lower.dropFirst(digits.count).trimmingCharacters(in: .whitespaces) {
        case "", "b": return number
        case "k", "kb": return number << 10
        case "m", "mb": return number << 20
        case "g", "gb": return number << 30
        case "t", "tb": return number << 40
        default: return nil
        }
    }
}
