import Foundation

/// Reads from an image registry over the OCI distribution API: the digest it
/// serves for a tag (`HEAD /v2/<repo>/manifests/<tag>`) and a repository's
/// tags (`GET /v2/<repo>/tags/list`). Takes the bearer token the registry asks
/// for: anonymous, or with a login for private repositories.
public struct RegistryClient: Sendable {
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let send: Send

    public struct Credentials: Sendable, Equatable {
        public let username: String
        public let password: String

        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    public init(send: @escaping Send = RegistryClient.urlSession) {
        self.send = send
    }

    public static let urlSession: Send = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    static let accept = [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ].joined(separator: ", ")

    /// `docker.io/library/redis:7-alpine` → (registry host, repository, tag).
    public static func split(_ reference: String) -> (host: String, repository: String, tag: String)? {
        guard !reference.contains("@") else { return nil }     // pinned by digest: nothing to update
        var parts = reference.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].contains(".") || parts[0].contains(":") else { return nil }
        let host = apiHost(parts[0])
        var rest = parts[1]
        var tag = "latest"
        if let colon = rest.lastIndex(of: ":"), !rest[colon...].contains("/") {
            tag = String(rest[rest.index(after: colon)...])
            rest = String(rest[..<colon])
        }
        parts = [host, rest]
        return (host, rest, tag)
    }

    /// The digest served for a fully qualified reference; nil for private
    /// images and digest-pinned references.
    public func digest(of reference: String) async throws -> String? {
        guard let (host, repository, tag) = Self.split(reference),
              let url = URL(string: "https://\(host)/v2/\(repository)/manifests/\(tag)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        request.setValue(Self.accept, forHTTPHeaderField: "Accept")
        let (_, response) = try await authorized(request, repository: repository, credentials: nil)
        guard response.statusCode == 200 else { return nil }
        return response.value(forHTTPHeaderField: "Docker-Content-Digest")
    }

    /// The image's OCI config (ports it exposes, volumes, environment) for
    /// `architecture`, read from the registry without pulling: manifest (or
    /// index → the platform's manifest), then the config blob.
    public func config(of reference: String, architecture: String = "arm64",
                       credentials: Credentials? = nil) async throws -> ImageDetails.OCIConfig? {
        guard let (host, repository, tag) = Self.split(reference) else { return nil }
        func get(_ path: String, accept: String?) async throws -> Data? {
            guard let url = URL(string: "https://\(host)/v2/\(repository)/\(path)") else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 15)
            if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
            let (data, response) = try await authorized(request, repository: repository, credentials: credentials)
            return response.statusCode == 200 ? data : nil
        }
        struct Manifest: Decodable {
            struct Descriptor: Decodable {
                struct Platform: Decodable { let architecture: String?; let os: String? }
                let digest: String
                let platform: Platform?
            }
            let manifests: [Descriptor]?
            let config: Descriptor?
        }
        guard let data = try await get("manifests/\(tag)", accept: Self.accept) else { return nil }
        var manifest = try JSONDecoder().decode(Manifest.self, from: data)
        if let entries = manifest.manifests {
            let linux = entries.filter { $0.platform?.os == "linux" }
            guard let entry = linux.first(where: { $0.platform?.architecture == architecture }) ?? linux.first,
                  let platformData = try await get("manifests/\(entry.digest)", accept: Self.accept) else { return nil }
            manifest = try JSONDecoder().decode(Manifest.self, from: platformData)
        }
        guard let config = manifest.config,
              let blob = try await get("blobs/\(config.digest)", accept: nil) else { return nil }
        return try JSONDecoder().decode(ImageDetails.OCIConfig.self, from: blob)
    }

    /// The registry host to talk to: Docker Hub's API lives on registry-1.
    public static func apiHost(_ registry: String) -> String {
        registry == "docker.io" ? "registry-1.docker.io" : registry
    }

    /// Every tag of `repository` on `registry` (`docker.io`, `ghcr.io`, …),
    /// following `Link` pages up to `pageLimit`; ordered as `ranked`.
    public func tags(registry: String, repository: String, credentials: Credentials? = nil,
                     pageLimit: Int = 5) async throws -> [String] {
        let host = Self.apiHost(registry)
        var next = URL(string: "https://\(host)/v2/\(repository)/tags/list?n=10000")
        var tags: [String] = []
        var pages = 0
        while let url = next, pages < pageLimit {
            pages += 1
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await authorized(request, repository: repository, credentials: credentials)
            switch response.statusCode {
            case 200: break
            case 401, 403: throw RegistryError.unauthorized(repository)
            case 404: throw RegistryError.notFound(repository)
            default: throw RegistryError.status(response.statusCode)
            }
            struct Page: Decodable { let tags: [String]? }
            tags += try JSONDecoder().decode(Page.self, from: data).tags ?? []
            next = response.value(forHTTPHeaderField: "Link").flatMap { Self.nextPage($0, relativeTo: url) }
        }
        return Self.ranked(tags)
    }

    public enum RegistryError: Error, LocalizedError, Equatable {
        case unauthorized(String)
        case notFound(String)
        case status(Int)

        public var errorDescription: String? {
            switch self {
            case .unauthorized(let repository): return String(localized: "\(repository) is private: sign in to its registry in Settings › Registries.")
            case .notFound(let repository): return String(localized: "No repository \(repository).")
            case .status(let code): return String(localized: "The registry answered \(String(code)).")
            }
        }
    }

    /// `</v2/x/tags/list?n=100&last=b>; rel="next"` → that URL.
    static func nextPage(_ link: String, relativeTo base: URL) -> URL? {
        guard link.contains(#"rel="next""#), let open = link.firstIndex(of: "<"),
              let close = link[open...].firstIndex(of: ">") else { return nil }
        return URL(string: String(link[link.index(after: open)..<close]), relativeTo: base)?.absoluteURL
    }

    /// Most useful first: `latest`, then version tags newest first (`25`,
    /// `25-alpine`, `25.1`, … `24`), then named ones (`alpine`, `lts`).
    public static func ranked(_ tags: [String]) -> [String] {
        func version(_ tag: String) -> [Int]? {
            let head = tag.prefix { $0.isNumber || $0 == "." }
            guard let first = head.first, first.isNumber else { return nil }
            return head.split(separator: ".").compactMap { Int($0) }
        }
        func before(_ a: String, _ b: String) -> Bool {
            if (a == "latest") != (b == "latest") { return a == "latest" }
            switch (version(a), version(b)) {
            case let (x?, y?):
                for (p, q) in zip(x, y) where p != q { return p > q }
                if x.count != y.count { return x.count < y.count }
                if a.count != b.count { return a.count < b.count }
                return a < b
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.count != b.count ? a.count < b.count : a < b
            }
        }
        return tags.sorted(by: before)
    }

    /// Send `request`; on a bearer challenge fetch a token and send it again.
    func authorized(_ request: URLRequest, repository: String,
                    credentials: Credentials?) async throws -> (Data, HTTPURLResponse) {
        var request = request
        var (data, response) = try await send(request)
        if response.statusCode == 401, let challenge = response.value(forHTTPHeaderField: "WWW-Authenticate"),
           let token = try await token(challenge, repository: repository, credentials: credentials) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            (data, response) = try await send(request)
        }
        return (data, response)
    }

    /// `Bearer realm="…",service="…",scope="…"` → a pull token, signed in
    /// with `credentials` when given.
    func token(_ challenge: String, repository: String, credentials: Credentials? = nil) async throws -> String? {
        let fields = Self.challengeFields(challenge)
        guard let realm = fields["realm"], var components = URLComponents(string: realm) else { return nil }
        var items: [URLQueryItem] = []
        if let service = fields["service"] { items.append(URLQueryItem(name: "service", value: service)) }
        items.append(URLQueryItem(name: "scope", value: fields["scope"] ?? "repository:\(repository):pull"))
        components.queryItems = items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        if let credentials {
            let basic = Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString()
            request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await send(request)
        guard response.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["token"] ?? object["access_token"]) as? String
    }

    static func challengeFields(_ challenge: String) -> [String: String] {
        var fields: [String: String] = [:]
        let body = challenge.drop { $0 != " " }
        let pattern = try! NSRegularExpression(pattern: #"(\w+)="([^"]*)""#)
        let text = String(body)
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let key = Range(match.range(at: 1), in: text), let value = Range(match.range(at: 2), in: text) {
                fields[String(text[key])] = String(text[value])
            }
        }
        return fields
    }
}
