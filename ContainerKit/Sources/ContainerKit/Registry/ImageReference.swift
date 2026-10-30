import Foundation

/// Docker image reference normalization: `alpine` → `docker.io/library/alpine:latest`,
/// `me/app` → `docker.io/me/app:latest`, `ghcr.io/x/y` → `ghcr.io/x/y:latest`.
public struct ImageReference: Equatable, Sendable {
    public let registry: String
    public let repository: String
    public let tag: String?
    public let digest: String?

    public init?(_ text: String) {
        var rest = text.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, !rest.contains(" ") else { return nil }
        var digest: String?
        if let at = rest.firstIndex(of: "@") {
            digest = String(rest[rest.index(after: at)...])
            rest = String(rest[..<at])
        }
        var components = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.contains(where: \.isEmpty) else { return nil }
        let first = components[0]
        let hasRegistry = components.count > 1 && (first.contains(".") || first.contains(":") || first == "localhost")
        registry = hasRegistry ? components.removeFirst() : "docker.io"
        var last = components.removeLast()
        var tag: String?
        if let colon = last.lastIndex(of: ":") {
            tag = String(last[last.index(after: colon)...])
            last = String(last[..<colon])
        }
        components.append(last)
        if registry == "docker.io" && components.count == 1 { components.insert("library", at: 0) }
        repository = components.joined(separator: "/").lowercased()
        self.tag = tag ?? (digest == nil ? "latest" : nil)
        self.digest = digest
    }

    /// Full form `container` uses: `docker.io/library/alpine:latest`.
    public var canonical: String {
        var text = "\(registry)/\(repository)"
        if let tag { text += ":\(tag)" }
        if let digest { text += "@\(digest)" }
        return text
    }

    /// What `docker` prints: `alpine:latest`, `me/app:1`, `ghcr.io/x/y:2`.
    public var familiar: String {
        var name = registry == "docker.io"
            ? (repository.hasPrefix("library/") ? String(repository.dropFirst(8)) : repository)
            : "\(registry)/\(repository)"
        if let tag { name += ":\(tag)" }
        if let digest { name += "@\(digest)" }
        return name
    }
}
