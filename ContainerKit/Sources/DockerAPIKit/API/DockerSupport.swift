import Foundation

/// An API failure with Docker's status code and wording.
public struct DockerAPIError: Error, LocalizedError, Sendable, Equatable {
    public let status: Int
    public let message: String

    public init(_ status: Int, _ message: String) {
        self.status = status
        self.message = message
    }

    public static func noSuchContainer(_ reference: String) -> DockerAPIError {
        DockerAPIError(404, "No such container: \(reference)")
    }

    public static func badParameter(_ message: String) -> DockerAPIError {
        DockerAPIError(400, message)
    }

    public var response: HTTPResponse { .error(status, message) }
    public var errorDescription: String? { message }
}

/// Docker's `filters` query parameter: `{"key":["a","b"]}`, or the legacy
/// `{"key":{"a":true}}` that older clients still send.
public struct DockerFilters: Sendable, Equatable {
    public private(set) var values: [String: [String]] = [:]

    public init(_ values: [String: [String]] = [:]) {
        self.values = values
    }

    public init(query: String?) throws {
        guard let query, !query.isEmpty else { return }
        guard let object = try? JSONSerialization.jsonObject(with: Data(query.utf8)) as? [String: Any] else {
            throw DockerAPIError.badParameter("invalid filter: \(query)")
        }
        for (key, value) in object {
            if let list = value as? [String] {
                values[key] = list
            } else if let map = value as? [String: Bool] {
                values[key] = map.filter(\.value).map(\.key).sorted()
            } else {
                throw DockerAPIError.badParameter("invalid filter '\(key)'")
            }
        }
    }

    public subscript(key: String) -> [String] { values[key] ?? [] }

    /// Keys outside `allowed` are an error, as with Docker.
    public func validate(_ allowed: Set<String>) throws {
        if let unknown = values.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw DockerAPIError.badParameter("invalid filter '\(unknown)'")
        }
    }

    /// `label` filters: `key` (present) or `key=value`.
    public func matchesLabels(_ labels: [String: String]) -> Bool {
        self["label"].allSatisfy { filter in
            let parts = filter.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { return labels[parts[0]] == parts[1] }
            return labels[parts[0]] != nil
        }
    }
}

/// Docker's `HumanDuration` (go-units), so `docker ps` reads the same.
public enum HumanDuration {
    public static func string(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        if seconds < 1 { return "Less than a second" }
        if seconds == 1 { return "1 second" }
        if seconds < 60 { return "\(seconds) seconds" }
        let minutes = Int(interval / 60)
        if minutes == 1 { return "About a minute" }
        if minutes < 60 { return "\(minutes) minutes" }
        let hours = Int(interval / 3600 + 0.5)
        if hours == 1 { return "About an hour" }
        if hours < 48 { return "\(hours) hours" }
        if hours < 24 * 7 * 2 { return "\(hours / 24) days" }
        if hours < 24 * 30 * 2 { return "\(hours / 24 / 7) weeks" }
        if hours < 24 * 365 * 2 { return "\(hours / 24 / 30) months" }
        return "\(Int(interval / 3600) / 24 / 365) years"
    }
}

/// Docker's timestamp format (RFC 3339 with nanoseconds); the zero time for
/// "never".
enum DockerTime {
    static let zero = "0001-01-01T00:00:00Z"

    static func string(_ date: Date?) -> String {
        guard let date else { return zero }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// A point in time as filters give it: Unix seconds (fractions allowed),
    /// RFC 3339, or a Go duration back from now (`24h`, `1h30m`, `90s`).
    static func moment(_ text: String, now: Date = Date()) -> Date? {
        if let seconds = Double(text) { return Date(timeIntervalSince1970: seconds) }
        if let date = parse(text) { return date }
        var total: TimeInterval = 0
        var number = ""
        var rest = Substring(text)
        guard !rest.isEmpty else { return nil }
        while let character = rest.first {
            if character.isNumber || character == "." {
                number.append(character)
                rest = rest.dropFirst()
                continue
            }
            guard let value = Double(number) else { return nil }
            let unit: TimeInterval
            if rest.hasPrefix("ms") { unit = 0.001; rest = rest.dropFirst(2) }
            else if character == "h" { unit = 3600; rest = rest.dropFirst() }
            else if character == "m" { unit = 60; rest = rest.dropFirst() }
            else if character == "s" { unit = 1; rest = rest.dropFirst() }
            else { return nil }
            total += value * unit
            number = ""
        }
        guard number.isEmpty else { return nil }
        return now.addingTimeInterval(-total)
    }
}

extension HTTPResponse {
    static let noContent = HTTPResponse(status: 204)
    static let notModified = HTTPResponse(status: 304)
}

/// Run a handler body, turning errors into Docker error responses.
func respond(_ body: () async throws -> HTTPResponse) async -> HTTPResponse {
    do {
        return try await body()
    } catch let error as DockerAPIError {
        return error.response
    } catch {
        return .error(500, error.localizedDescription)
    }
}

extension DockerRequest {
    /// `1`, `true` (any case) → true; absent → `default`.
    func bool(_ name: String, default value: Bool = false) -> Bool {
        guard let raw = query[name] else { return value }
        return ["1", "true", "yes"].contains(raw.lowercased())
    }

    func int(_ name: String) throws -> Int? {
        guard let raw = query[name], !raw.isEmpty else { return nil }
        guard let value = Int(raw) else { throw DockerAPIError.badParameter("invalid value for \(name): \(raw)") }
        return value
    }
}
