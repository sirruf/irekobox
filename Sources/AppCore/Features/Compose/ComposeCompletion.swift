import Foundation

/// What to offer while typing a compose file, from where the cursor is:
/// keys for the mapping it's in, values for keys with a known set, service
/// and network names where they're referenced, local images for `image:`.
/// Works line by line on indentation, so a half-typed file is fine.
enum ComposeCompletion {
    struct Suggestions: Equatable {
        /// The text the choice replaces (the word being typed).
        let range: NSRange
        let items: [Item]
    }

    struct Item: Hashable, Identifiable {
        /// What the list shows and typing matches.
        let label: String
        /// What Return inserts.
        let insert: String
        let detail: String
        /// What Tab inserts (two-space indents, fitted on insert).
        var block: String?
        /// A named volume to declare at the top level with the block.
        var volume: String?

        var id: String { label }
    }

    static let topKeys = ["services", "networks", "volumes", "name", "configs", "secrets", "include"]

    /// Ones `container` runs as written or the app handles come first.
    static let serviceKeys = [
        "image", "build", "command", "entrypoint", "environment", "env_file", "ports", "volumes",
        "depends_on", "networks", "restart", "healthcheck", "container_name", "working_dir", "user",
        "labels", "cpus", "mem_limit", "read_only", "init", "tty", "stdin_open", "cap_add", "cap_drop",
        "dns", "platform", "shm_size", "profiles", "scale", "deploy",
        "hostname", "expose", "extra_hosts", "network_mode", "secrets", "configs", "logging",
        "ulimits", "sysctls", "privileged", "security_opt", "pull_policy", "stop_signal",
        "stop_grace_period", "extends", "devices", "tmpfs", "ipc", "pid", "develop",
    ]

    static let nestedKeys: [String: [String]] = [
        "healthcheck": ["test", "interval", "timeout", "retries", "start_period", "start_interval", "disable"],
        "build": ["context", "dockerfile", "args", "target", "platforms", "tags", "cache_from", "secrets"],
        "deploy": ["resources", "replicas", "restart_policy", "labels"],
        "logging": ["driver", "options"],
    ]

    static let dependencyKeys = ["condition", "restart", "required"]
    static let resourceKeys = ["external", "name", "driver", "driver_opts", "labels"]

    static let values: [String: [String]] = [
        "restart": ["no", "always", "on-failure", "unless-stopped"],
        "condition": ["service_started", "service_healthy", "service_completed_successfully"],
        "pull_policy": ["always", "missing", "never", "build"],
        "read_only": ["true", "false"], "init": ["true", "false"], "tty": ["true", "false"],
        "stdin_open": ["true", "false"], "privileged": ["true", "false"], "external": ["true", "false"],
        "required": ["true", "false"], "disable": ["true", "false"],
        "platform": ["linux/arm64", "linux/amd64"],
    ]

    /// Where the cursor is: the word being typed, its range, what precedes
    /// it on the line and the keys it sits under.
    struct Context {
        let range: NSRange
        let word: String
        let head: String
        let path: [String]
    }

    static func context(in text: String, at cursor: Int) -> Context? {
        let ns = text as NSString
        guard cursor <= ns.length else { return nil }
        let lineStart = ns.lineRange(for: NSRange(location: cursor, length: 0)).location
        let before = ns.substring(with: NSRange(location: lineStart, length: cursor - lineStart))
        if before.trimmingCharacters(in: .whitespaces).hasPrefix("#") { return nil }

        // The word being typed: back to a space, `[`, `,`, `:` start or `- `.
        let stops = CharacterSet(charactersIn: " \t[,\"'")
        var wordStart = before.utf16.count
        for (offset, unit) in before.utf16.enumerated().reversed() {
            guard let scalar = Unicode.Scalar(unit), !stops.contains(scalar) else { break }
            wordStart = offset
        }
        let word = String(before.utf16.dropFirst(wordStart)) ?? ""
        let head = String(before.utf16.prefix(wordStart)) ?? ""
        let range = NSRange(location: lineStart + wordStart, length: before.utf16.count - wordStart)
        let indent = before.prefix { $0 == " " }.count
        return Context(range: range, word: word, head: head.trimmingCharacters(in: .whitespaces),
                       path: parents(of: ns.substring(to: lineStart), indent: indent))
    }

    /// The image being typed when the cursor is on a service's `image:`.
    static func imageValue(in text: String, at cursor: Int) -> (range: NSRange, word: String)? {
        guard let context = context(in: text, at: cursor), valueKey(context.head) == "image",
              context.path.count >= 2, context.path[0] == "services" else { return nil }
        return (context.range, context.word)
    }

    /// Suggestions at `cursor` (UTF-16 offset) in `text`.
    static func suggest(in text: String, at cursor: Int, images: [String] = []) -> Suggestions? {
        guard let context = context(in: text, at: cursor) else { return nil }
        let (range, word, trimmedHead, path) = (context.range, context.word, context.head, context.path)

        var items: [Item]
        if let key = valueKey(trimmedHead) {
            // `key: wor|` or `key: [a, wor|`
            items = valueItems(for: key, path: path, text: text, images: images)
        } else if trimmedHead == "-" {
            // A list item under a key.
            items = valueItems(for: path.last ?? "", path: Array(path.dropLast()), text: text, images: images)
        } else if trimmedHead.isEmpty, !word.contains(":") {
            items = keyItems(path: path)
        } else {
            return nil
        }
        let lower = word.lowercased()
        let matching = items.filter { lower.isEmpty || $0.label.lowercased().hasPrefix(lower) }
            .filter { $0.label.lowercased() != lower }
        guard !matching.isEmpty else { return nil }
        return Suggestions(range: range, items: matching)
    }

    // MARK: - Context

    /// Keys of the mappings enclosing a line indented by `indent`, outermost
    /// first (`["services", "web"]`).
    static func parents(of text: String, indent: Int) -> [String] {
        var path: [String] = []
        var limit = indent
        for line in text.components(separatedBy: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let level = line.prefix { $0 == " " }.count
            guard level < limit else { continue }
            var content = trimmed
            if content.hasPrefix("- ") { content = String(content.dropFirst(2)) }
            if let colon = content.firstIndex(of: ":") {
                path.insert(String(content[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")), at: 0)
            }
            limit = level
            if level == 0 { break }
        }
        return path
    }

    /// `restart:` / `depends_on: [db,` → the key, when the cursor is in its value.
    static func valueKey(_ head: String) -> String? {
        var text = head
        if text.hasPrefix("- ") { text = String(text.dropFirst(2)) }
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty || rest.hasPrefix("[") else { return nil }
        let key = String(text[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        return key.contains(" ") ? nil : key
    }

    static func keyItems(path: [String]) -> [Item] {
        func keys(_ names: [String], _ details: [String: String], blocks: Bool) -> [Item] {
            names.map { Item(label: $0, insert: $0 + ": ", detail: details[$0] ?? "",
                             block: blocks ? ComposeCatalog.blocks[$0] : nil) }
        }
        switch path.count {
        case 0: return keys(topKeys, ComposeCatalog.topKeys, blocks: true)
        case 1 where path[0] == "services":
            // New services: names are the user's own, or start from a template.
            return ComposeCatalog.templates.map {
                Item(label: $0.name, insert: $0.block, detail: $0.detail, block: $0.block, volume: $0.volume)
            }
        case 2 where path[0] == "services": return keys(serviceKeys, ComposeCatalog.serviceKeys, blocks: true)
        case 2 where path[0] == "networks" || path[0] == "volumes":
            return keys(resourceKeys, ComposeCatalog.nestedKeys, blocks: false)
        case 3 where path[0] == "services":
            return keys(nestedKeys[path[2]] ?? [], ComposeCatalog.nestedKeys, blocks: false)
        case 4 where path[0] == "services" && path[2] == "depends_on":
            return keys(dependencyKeys, ComposeCatalog.nestedKeys, blocks: false)
        default: return []
        }
    }

    static func valueItems(for key: String, path: [String], text: String, images: [String]) -> [Item] {
        let inService = path.count >= 2 && path[0] == "services"
        func plain(_ values: [String], _ detail: String) -> [Item] {
            values.map { Item(label: $0, insert: $0, detail: detail) }
        }
        switch key {
        case "image" where inService: return plain(images, String(localized: "On this Mac."))
        case "depends_on" where inService, "links" where inService, "extends" where inService:
            let own = path.count >= 2 ? path[1] : ""
            return plain(names(under: "services", in: text).filter { $0 != own }, String(localized: "Service in this file."))
        case "networks" where inService:
            return plain(names(under: "networks", in: text), String(localized: "Network in this file."))
                + [Item(label: "default", insert: "default", detail: String(localized: "The project's own network."))]
        default:
            let details = ComposeCatalog.values[key] ?? [:]
            return (values[key] ?? []).map { Item(label: $0, insert: $0, detail: details[$0] ?? "") }
        }
    }

    // MARK: - Inserting blocks

    /// `block` (two-space indents, first line in place) fitted under a
    /// line starting at `column`, with the file's indent `unit`.
    static func expand(_ block: String, column: Int, unit: Int) -> String {
        block.components(separatedBy: "\n").enumerated().map { index, line in
            let depth = line.prefix { $0 == " " }.count / 2
            let body = line.drop { $0 == " " }
            let indent = index == 0 ? "" : String(repeating: " ", count: column + depth * unit)
            return indent + body
        }.joined(separator: "\n")
    }

    /// The indent step the file uses (2 when it can't tell).
    static func indentUnit(_ text: String) -> Int {
        let first = text.components(separatedBy: "\n").lazy
            .map { $0.prefix { $0 == " " }.count }.first { $0 > 0 }
        return first ?? 2
    }

    /// Where to add `volume` to the top-level `volumes:` (nil if it's there):
    /// the offset and the text to insert.
    static func volumeDeclaration(_ volume: String, in text: String) -> (offset: Int, insert: String)? {
        if names(under: "volumes", in: text).contains(volume) { return nil }
        let unit = String(repeating: " ", count: indentUnit(text))
        let ns = text as NSString
        let lines = text.components(separatedBy: "\n")
        var offset = 0
        for line in lines {
            let length = (line as NSString).length + 1
            if line.hasPrefix("volumes:") {
                return (min(offset + length, ns.length), (offset + length > ns.length ? "\n" : "") + "\(unit)\(volume):\n")
            }
            offset += length
        }
        let needsBreak = !text.hasSuffix("\n")
        return (ns.length, (needsBreak ? "\n" : "") + "volumes:\n\(unit)\(volume):\n")
    }

    /// Keys directly under a top-level `key:` (service or network names).
    static func names(under key: String, in text: String) -> [String] {
        var result: [String] = []
        var inside = false
        var childIndent: Int?
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let level = line.prefix { $0 == " " }.count
            if level == 0 {
                inside = trimmed.hasPrefix(key + ":")
                childIndent = nil
                continue
            }
            guard inside else { continue }
            if childIndent == nil { childIndent = level }
            if level == childIndent, let colon = trimmed.firstIndex(of: ":") {
                result.append(String(trimmed[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))
            }
        }
        return result
    }
}
