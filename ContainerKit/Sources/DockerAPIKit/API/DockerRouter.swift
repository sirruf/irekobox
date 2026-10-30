import Foundation

/// The API versions we answer to. Clients negotiate `min(theirs, current)`.
public enum DockerAPIVersion {
    public static let current = Version(1, 56)
    /// Lenient on purpose: Testcontainers and older SDKs pin low versions.
    public static let minimum = Version(1, 24)

    public struct Version: Comparable, Sendable, CustomStringConvertible {
        public let major: Int
        public let minor: Int
        public init(_ major: Int, _ minor: Int) { self.major = major; self.minor = minor }
        public init?(_ text: String) {
            let parts = text.split(separator: ".")
            guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
            self.init(major, minor)
        }
        public var description: String { "\(major).\(minor)" }
        public static func < (lhs: Version, rhs: Version) -> Bool {
            (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
        }
    }
}

/// A request matched to a route: path parameters and the API version used.
public struct DockerRequest: Sendable {
    public let http: HTTPRequest
    public let parameters: [String: String]
    public let apiVersion: DockerAPIVersion.Version

    public var query: [String: String] { http.query }
}

/// Routes Docker API paths (with or without a `/v1.NN` prefix) to handlers.
public struct DockerRouter: Sendable {
    public typealias Handler = @Sendable (DockerRequest) async -> HTTPResponse

    private struct Route: Sendable {
        let method: String
        let segments: [String]
        let handler: Handler
    }

    private var routes: [Route] = []
    /// Fallbacks for whole path prefixes (e.g. every `/swarm…` endpoint).
    private var prefixes: [(prefix: String, handler: Handler)] = []

    public init() {}

    /// `pattern` like `/containers/{id}/json`; `{name*}` takes one or more
    /// segments (image names: `me/app`, `ghcr.io/x/y:tag`).
    public mutating func add(_ method: String, _ pattern: String, _ handler: @escaping Handler) {
        routes.append(Route(method: method.uppercased(),
                            segments: pattern.split(separator: "/").map(String.init), handler: handler))
    }

    /// Answer every otherwise unmatched path under `prefix` (any method).
    public mutating func addPrefix(_ prefix: String, _ handler: @escaping Handler) {
        prefixes.append((prefix, handler))
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        var path = request.path
        var version = DockerAPIVersion.current
        if let match = path.firstMatch(of: /^\/v(\d+\.\d+)(\/.*)$/) {
            guard let requested = DockerAPIVersion.Version(String(match.1)) else {
                return .error(400, "malformed API version")
            }
            if requested < DockerAPIVersion.minimum {
                return .error(400, "client version \(requested) is too old. Minimum supported API version is \(DockerAPIVersion.minimum), please upgrade your client to a newer version")
            }
            if requested > DockerAPIVersion.current {
                return .error(400, "client version \(requested) is too new. Maximum supported API version is \(DockerAPIVersion.current)")
            }
            version = requested
            path = String(match.2)
        }

        let segments = path.split(separator: "/").map(String.init)
        // HEAD is served by the GET route without the body (the server drops it).
        let method = request.method == "HEAD" && !routes.contains { $0.method == "HEAD" && Self.match($0.segments, segments) != nil }
            ? "GET" : request.method
        for route in routes where route.method == method {
            if let parameters = Self.match(route.segments, segments) {
                return await route.handler(DockerRequest(http: request, parameters: parameters, apiVersion: version))
            }
        }
        for (prefix, handler) in prefixes where path == prefix || path.hasPrefix(prefix + "/") {
            return await handler(DockerRequest(http: request, parameters: [:], apiVersion: version))
        }
        return .error(404, "page not found")
    }

    private static func match(_ pattern: [String], _ segments: [String]) -> [String: String]? {
        if let wide = pattern.firstIndex(where: { $0.hasPrefix("{") && $0.hasSuffix("*}") }) {
            // Fixed segments before and after; the wide one takes the rest.
            let after = pattern.count - wide - 1
            guard segments.count >= pattern.count else { return nil }
            guard var parameters = match(Array(pattern[..<wide]), Array(segments[..<wide])),
                  let tail = match(Array(pattern[(wide + 1)...]), Array(segments[(segments.count - after)...])) else {
                return nil
            }
            parameters.merge(tail) { $1 }
            let name = String(pattern[wide].dropFirst().dropLast(2))
            parameters[name] = segments[wide..<(segments.count - after)].joined(separator: "/")
            return parameters
        }
        guard pattern.count == segments.count else { return nil }
        var parameters: [String: String] = [:]
        for (expected, actual) in zip(pattern, segments) {
            if expected.hasPrefix("{"), expected.hasSuffix("}") {
                parameters[String(expected.dropFirst().dropLast())] = actual
            } else if expected != actual {
                return nil
            }
        }
        return parameters
    }
}
