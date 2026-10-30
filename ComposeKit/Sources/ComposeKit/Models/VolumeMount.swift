import Foundation

/// A service volume. Supports short syntax (`"data:/var/lib"`, `"./src:/app:ro"`,
/// `"/abs:/x"`, `"/anon"`) and long object syntax (`type/source/target/read_only`).
public struct VolumeMount: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case bind, volume, anonymous, tmpfs
    }
    /// `nil` for an anonymous volume.
    public let source: String?
    public let target: String
    public let readOnly: Bool
    public let kind: Kind

    public init(source: String?, target: String, readOnly: Bool, kind: Kind) {
        self.source = source
        self.target = target
        self.readOnly = readOnly
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case type, source, target
        case readOnly = "read_only"
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let s = try? single.decode(String.self) {
            self = VolumeMount.parse(s)
            return
        }
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        let typeRaw = try keyed.decodeIfPresent(String.self, forKey: .type)
        let source = try keyed.decodeIfPresent(String.self, forKey: .source)
        let target = try keyed.decode(String.self, forKey: .target)
        let readOnly = try keyed.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        let kind = typeRaw.flatMap(Kind.init(rawValue:)) ?? (source == nil ? .anonymous : (VolumeMount.looksLikePath(source!) ? .bind : .volume))
        self = VolumeMount(source: source, target: target, readOnly: readOnly, kind: kind)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(shortSyntax)
    }

    /// `[source:]target[:ro]`.
    public var shortSyntax: String {
        var s = ""
        if let source { s += "\(source):" }
        s += target
        if readOnly { s += ":ro" }
        return s
    }

    static func looksLikePath(_ s: String) -> Bool {
        s.hasPrefix("/") || s.hasPrefix("./") || s.hasPrefix("../") || s.hasPrefix("~")
    }

    static func parse(_ input: String) -> VolumeMount {
        let parts = input.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            return VolumeMount(source: nil, target: parts[0], readOnly: false, kind: .anonymous)
        case 2:
            let named = !looksLikePath(parts[0])
            return VolumeMount(source: parts[0], target: parts[1], readOnly: false, kind: named ? .volume : .bind)
        default:
            let mode = parts[2]
            let named = !looksLikePath(parts[0])
            return VolumeMount(source: parts[0], target: parts[1],
                               readOnly: mode.contains("ro"), kind: named ? .volume : .bind)
        }
    }
}
