import Foundation

/// One HTTP/1.1 request as a Docker client sends it.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    /// Request target as sent: path plus optional `?query`.
    public var target: String
    /// "HTTP/1.1" or "HTTP/1.0".
    public var version: String
    /// Header fields in arrival order (names as sent).
    public var headers: [(name: String, value: String)]
    /// The body, unless it was too large to keep in memory.
    public var body: Data
    /// A large body, in a temporary file the server deletes after the response.
    public var bodyFile: URL?

    public init(method: String, target: String, version: String = "HTTP/1.1",
                headers: [(name: String, value: String)] = [], body: Data = Data()) {
        self.method = method
        self.target = target
        self.version = version
        self.headers = headers
        self.body = body
    }

    /// First value of a header, case-insensitively.
    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The path without the query, percent-decoded.
    public var path: String {
        let raw = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        return raw.removingPercentEncoding ?? raw
    }

    /// Query parameters; a repeated key keeps its last value, a bare key maps to "".
    public var query: [String: String] {
        guard let index = target.firstIndex(of: "?") else { return [:] }
        var result: [String: String] = [:]
        for pair in target[target.index(after: index)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ text: Substring) -> String {
                let spaced = text.replacingOccurrences(of: "+", with: " ")
                return spaced.removingPercentEncoding ?? spaced
            }
            result[decode(parts[0])] = parts.count > 1 ? decode(parts[1]) : ""
        }
        return result
    }

    /// Every value of a repeated query parameter (`names=a&names=b`).
    public func queryValues(_ name: String) -> [String] {
        guard let index = target.firstIndex(of: "?") else { return [] }
        return target[target.index(after: index)...].split(separator: "&").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ text: Substring) -> String {
                let spaced = text.replacingOccurrences(of: "+", with: " ")
                return spaced.removingPercentEncoding ?? spaced
            }
            guard decode(parts[0]) == name else { return nil }
            return parts.count > 1 ? decode(parts[1]) : ""
        }
    }

    /// Whether the connection stays open after the response.
    public var keepAlive: Bool {
        let connection = header("Connection")?.lowercased() ?? ""
        if version == "HTTP/1.0" { return connection.contains("keep-alive") }
        return !connection.contains("close")
    }

    /// The client asked to take over the connection (`Upgrade: tcp`), as the
    /// docker CLI does for attach and exec.
    public var wantsUpgrade: Bool {
        (header("Connection")?.lowercased().contains("upgrade") ?? false) && header("Upgrade") != nil
    }

    /// Write the body to `url`, moving the temporary file when there is one.
    public func saveBody(to url: URL) throws {
        if let bodyFile {
            try FileManager.default.moveItem(at: bodyFile, to: url)
        } else {
            try body.write(to: url)
        }
    }

    /// Remove a body file and the private folder holding it.
    static func removeBodyFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    public static func == (lhs: HTTPRequest, rhs: HTTPRequest) -> Bool {
        lhs.method == rhs.method && lhs.target == rhs.target && lhs.version == rhs.version
            && lhs.body == rhs.body && lhs.bodyFile == rhs.bodyFile
            && lhs.headers.map { "\($0.name):\($0.value)" } == rhs.headers.map { "\($0.name):\($0.value)" }
    }
}
