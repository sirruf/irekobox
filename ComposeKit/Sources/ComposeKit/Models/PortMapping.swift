import Foundation

/// A published port, per the Compose Specification. Short syntax
/// `[[HOST_IP:]HOST:]CONTAINER[/PROTOCOL]`, where HOST and CONTAINER are a
/// port or a range (`"80"`, `"8080:80"`, `"127.0.0.1:8080:80/udp"`,
/// `"[::1]:6001:6001"`, `"9090-9091:8080-8081"`, `"8080-8081:80"`), or the
/// long syntax (`target`, `published`, `host_ip`, `protocol`; `mode`,
/// `name` and `app_protocol` are informational here).
public struct PortMapping: Codable, Hashable, Sendable {
    /// Host port or range (`8080`, `8080-8081`). `nil` = container-only.
    public let published: String?
    /// Container port (the first of a range). `nil` when the spec could not be parsed.
    public let target: Int?
    /// Last container port of a range (`8080-8081` → 8081); nil for one port.
    public let targetEnd: Int?
    public let networkProtocol: String?
    public let hostIP: String?
    /// Original string, kept for diagnostics on unparseable specs.
    public let raw: String?

    public init(published: String?, target: Int?, targetEnd: Int? = nil, networkProtocol: String?,
                hostIP: String?, raw: String? = nil) {
        self.published = published
        self.target = target
        self.targetEnd = targetEnd
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
        let targetText = try keyed.decodeIfPresent(ScalarValue.self, forKey: .target)?.stringValue
        let range = targetText.flatMap(Self.portRange)
        let published = try keyed.decodeIfPresent(ScalarValue.self, forKey: .published)?.stringValue
        let proto = try keyed.decodeIfPresent(String.self, forKey: .networkProtocol)
        let hostIP = try keyed.decodeIfPresent(String.self, forKey: .hostIP)
        self = PortMapping(published: published?.isEmpty == true ? nil : published,
                           target: range?.lowerBound, targetEnd: range.flatMap { $0.count > 1 ? $0.upperBound : nil },
                           networkProtocol: proto, hostIP: hostIP, raw: targetText)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(shortSyntax)
    }

    /// The mapping in short syntax, as written in a compose file.
    public var shortSyntax: String {
        var s = Self.hostIPPrefix(hostIP)
        if let published { s += "\(published):" }
        if let target {
            s += targetEnd.map { "\(target)-\($0)" } ?? String(target)
        } else {
            s += raw ?? ""
        }
        if let networkProtocol { s += "/\(networkProtocol)" }
        return s
    }

    /// Why a mapping publishes nothing.
    public enum PublishProblem: Error, Hashable, Sendable {
        /// Not a port or range the spec allows.
        case unparseable
        /// No host port: `container` publishes only to a given one.
        case noHostPort
        /// HOST and CONTAINER ranges of different lengths.
        case mismatchedRanges
        /// A host range with fewer ports than replicas: `replica` gets none.
        case rangeTooSmall(replica: Int)
    }

    /// Whether every replica can publish this without colliding: one
    /// container port onto a host range with a port for each.
    public func fitsReplicas(_ replicas: Int) -> Bool {
        guard replicas > 1 else { return true }
        guard target != nil, targetEnd == nil, let published, let range = Self.portRange(published) else { return false }
        return range.count >= replicas
    }

    /// `--publish` values for replica `replica` (1-based). A host range for
    /// one container port gives each replica the next port of the range, as
    /// Docker does when it picks the first free one; equal ranges map port
    /// by port.
    public func publishSpecs(replica: Int = 1) -> Result<[String], PublishProblem> {
        guard let target else { return .failure(.unparseable) }
        guard let published else { return .failure(.noHostPort) }
        guard let host = Self.portRange(published) else { return .failure(.unparseable) }
        let container = target...(targetEnd ?? target)
        let suffix = networkProtocol.map { "/\($0)" } ?? ""
        let prefix = Self.hostIPPrefix(hostIP)
        func spec(_ hostPort: Int, _ containerPort: Int) -> String { "\(prefix)\(hostPort):\(containerPort)\(suffix)" }

        if container.count > 1 {
            guard host.count == container.count else { return .failure(.mismatchedRanges) }
            return .success(zip(host, container).map(spec))
        }
        if host.count > 1 {
            let port = host.lowerBound + replica - 1
            guard host.contains(port) else { return .failure(.rangeTooSmall(replica: replica)) }
            return .success([spec(port, target)])
        }
        return .success([spec(host.lowerBound, target)])
    }

    /// `"8080"` → 8080...8080, `"8080-8081"` → 8080...8081; nil if invalid.
    static func portRange(_ text: String) -> ClosedRange<Int>? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, (1...2).contains(numbers.count),
              let low = numbers.first, let high = numbers.last,
              1 <= low, low <= high, high <= 65535 else { return nil }
        return low...high
    }

    /// `127.0.0.1:`, `[::1]:` (an IPv6 address goes in brackets), or empty.
    static func hostIPPrefix(_ hostIP: String?) -> String {
        guard let hostIP, !hostIP.isEmpty else { return "" }
        return hostIP.contains(":") ? "[\(hostIP)]:" : "\(hostIP):"
    }

    /// Parse compose short syntax; an invalid spec has `target == nil`.
    static func parse(_ input: String) -> PortMapping {
        var rest = input.trimmingCharacters(in: .whitespaces)
        var proto: String?
        if let slash = rest.lastIndex(of: "/") {
            proto = String(rest[rest.index(after: slash)...])
            rest = String(rest[..<slash])
        }
        func invalid() -> PortMapping {
            PortMapping(published: nil, target: nil, networkProtocol: proto, hostIP: nil, raw: input)
        }

        // An IPv6 host address is bracketed: `[::1]:6001:6001`.
        var hostIP: String?
        if rest.hasPrefix("[") {
            guard let close = rest.range(of: "]:") else { return invalid() }
            hostIP = String(rest[rest.index(after: rest.startIndex)..<close.lowerBound])
            rest = String(rest[close.upperBound...])
        }
        var parts = rest.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if hostIP == nil, parts.count == 3 { hostIP = parts.removeFirst() }
        if let ip = hostIP, ip.isEmpty { hostIP = nil }

        let published: String?
        switch parts.count {
        case 1: published = nil
        case 2: published = parts[0].isEmpty ? nil : parts[0]
        default: return invalid()
        }
        guard let container = portRange(parts[parts.count - 1]) else { return invalid() }
        return PortMapping(published: published, target: container.lowerBound,
                           targetEnd: container.count > 1 ? container.upperBound : nil,
                           networkProtocol: proto, hostIP: hostIP, raw: input)
    }
}
