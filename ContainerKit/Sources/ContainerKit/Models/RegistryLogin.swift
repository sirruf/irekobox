import Foundation

/// A registry login as reported by `container registry ls --format json`.
///
/// CLI 1.6.1 emits `name`/`id` (host), `username`, `creationDate`,
/// `modificationDate`; older spellings are still accepted.
public struct RegistryLogin: Codable, Identifiable, Hashable, Sendable {
    public let hostname: String
    public let username: String?
    public let modified: String?
    public let created: String?

    public var id: String { hostname }

    public init(hostname: String, username: String? = nil, modified: String? = nil, created: String? = nil) {
        self.hostname = hostname
        self.username = username
        self.modified = modified
        self.created = created
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func first(_ keys: [String]) -> String? {
            for key in keys {
                if let value = try? c.decode(String.self, forKey: AnyKey(key)) { return value }
            }
            return nil
        }
        hostname = first(["name", "id", "hostname", "host", "server", "registry"]) ?? "unknown"
        username = first(["username", "user", "userName"])
        modified = first(["modificationDate", "modified", "modifiedAt"])
        created = first(["creationDate", "created", "createdAt"])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(hostname, forKey: AnyKey("hostname"))
        try c.encodeIfPresent(username, forKey: AnyKey("username"))
    }
}
