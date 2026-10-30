import Foundation

/// A published port. Supports compose short syntax
/// (`"8080:80"`, `"127.0.0.1:8080:80/tcp"`, `"80"`) and long object syntax.
public struct PortMapping: Codable, Hashable, Sendable {
    /// Host port (or `ip:port` when host IP is set). `nil` = container-only.
    public let published: String?
    /// Container port. `nil` when the spec could not be parsed (e.g. a range).
    public let target: Int?
    public let networkProtocol: String?
    public let hostIP: String?
    /// Original string, kept for diagnostics on unparseable specs.
    public let raw: String?

    public init(published: String?, target: Int?, networkProtocol: String?, hostIP: String?, raw: String? = nil) {
        self.published = published
        self.target = target
        self.networkProtocol = networkProtocol
        self.hostIP = hostIP
        self.raw = raw
    }

    enum CodingKeys: String, CodingKey {
        case target, published
        case hostIP = "host_ip"
        case networkProtocol = "protocol"
        case mode
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let i = try? single.decode(Int.self) {
            self = PortMapping(published: nil, target: i, networkProtocol: nil, hostIP: nil)
            return
        }
        if let s = try? single.decode(String.self) {
            self = PortMapping.parse(s)
            return
        }
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        let target = try keyed.decodeIfPresent(Int.self, forKey: .target)
        let published = try keyed.decodeIfPresent(ScalarValue.self, forKey: .published)?.stringValue
        let proto = try keyed.decodeIfPresent(String.self, forKey: .networkProtocol)
        let hostIP = try keyed.decodeIfPresent(String.self, forKey: .hostIP)
        self = PortMapping(published: published, target: target, networkProtocol: proto, hostIP: hostIP)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(shortSyntax)
    }

    /// `[host-ip:]host:container[/proto]` for `container run --publish`.
    public var shortSyntax: String {
        var s = ""
        if let hostIP { s += "\(hostIP):" }
        if let published { s += "\(published):" }
        s += target.map(String.init) ?? (raw ?? "")
        if let networkProtocol { s += "/\(networkProtocol)" }
        return s
    }

    /// Parse compose short syntax. Ranges (`8000-8001`) are left unparsed (`target == nil`).
    static func parse(_ input: String) -> PortMapping {
        var rest = input
        var proto: String?
        if let slash = rest.firstIndex(of: "/") {
            proto = String(rest[rest.index(after: slash)...])
            rest = String(rest[..<slash])
        }

        let parts = rest.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        func port(_ s: String) -> Int? { s.contains("-") ? nil : Int(s) }

        switch parts.count {
        case 1:
            return PortMapping(published: nil, target: port(parts[0]), networkProtocol: proto, hostIP: nil, raw: input)
        case 2:
            return PortMapping(published: parts[0], target: port(parts[1]), networkProtocol: proto, hostIP: nil, raw: input)
        case 3:
            return PortMapping(published: parts[1], target: port(parts[2]), networkProtocol: proto, hostIP: parts[0], raw: input)
        default:
            return PortMapping(published: nil, target: nil, networkProtocol: proto, hostIP: nil, raw: input)
        }
    }
}
