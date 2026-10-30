import Foundation

/// A Docker Hub search result, in the Docker API's shape.
public struct SearchResult: Codable, Sendable, Hashable {
    public let name: String
    public let description: String
    public let star_count: Int
    public let is_official: Bool
    public let is_automated: Bool

    public init(name: String, description: String, star_count: Int, is_official: Bool, is_automated: Bool) {
        self.name = name
        self.description = description
        self.star_count = star_count
        self.is_official = is_official
        self.is_automated = is_automated
    }
}

/// Docker Hub's v1 index search, as dockerd uses for `docker search`.
public enum DockerHubSearch {
    struct Response: Decodable {
        let results: [SearchResult]
    }

    public static func search(_ term: String, _ limit: Int) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://index.docker.io/v1/search")!
        components.queryItems = [URLQueryItem(name: "q", value: term), URLQueryItem(name: "n", value: String(limit))]
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return Array(try JSONDecoder().decode(Response.self, from: data).results.prefix(limit))
    }
}
