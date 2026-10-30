import Foundation
import Observation

/// Looks up the latest apple/container release on GitHub — at most once a day,
/// and only when enabled in Settings — so the Overview can say an update exists.
@MainActor
@Observable
final class ContainerUpdateCheck {
    struct Release: Equatable, Decodable {
        let version: String
        let url: URL

        enum CodingKeys: String, CodingKey {
            case version = "tag_name"
            case url = "html_url"
        }
    }

    static let endpoint = URL(string: "https://api.github.com/repos/apple/container/releases/latest")!
    static let interval: TimeInterval = 24 * 3600

    private(set) var latest: Release?

    private let defaults: UserDefaults
    private let fetch: @Sendable (URL) async throws -> Data

    init(defaults: UserDefaults = .standard,
         fetch: @escaping @Sendable (URL) async throws -> Data = ContainerUpdateCheck.download) {
        self.defaults = defaults
        self.fetch = fetch
        self.isEnabled = defaults.object(forKey: "checkContainerUpdates") as? Bool ?? true
        if let data = defaults.data(forKey: "containerLatestRelease") {
            latest = try? JSONDecoder().decode(Release.self, from: data)
        }
    }

    /// Stored (not computed from defaults) so SwiftUI observes changes.
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: "checkContainerUpdates") }
    }

    /// The newer release, if `installed` is behind it.
    func update(over installed: String?) -> Release? {
        guard isEnabled, let installed, let latest,
              Self.compare(latest.version, installed) == .orderedDescending else { return nil }
        return latest
    }

    /// Check if the last check is older than a day (or `force`).
    func checkIfDue(force: Bool = false) async {
        guard isEnabled else { return }
        let last = defaults.double(forKey: "containerLastUpdateCheck")
        guard force || Date().timeIntervalSince1970 - last > Self.interval else { return }
        do {
            let data = try await fetch(Self.endpoint)
            let release = try JSONDecoder().decode(Release.self, from: data)
            latest = release
            defaults.set(try JSONEncoder().encode(EncodableRelease(release)), forKey: "containerLatestRelease")
            defaults.set(Date().timeIntervalSince1970, forKey: "containerLastUpdateCheck")
        } catch {
            // Offline or rate-limited: keep what we knew; try again next time.
        }
    }

    /// Numeric comparison of dotted versions, ignoring a leading "v" and
    /// anything after a "-" ("1.10.0" > "1.9.2").
    nonisolated static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func parts(_ version: String) -> [Int] {
            let core = version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                .split(separator: "-").first.map(String.init) ?? version
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(lhs), b = parts(rhs)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    nonisolated static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private struct EncodableRelease: Encodable {
        let tag_name: String
        let html_url: URL
        init(_ release: Release) { tag_name = release.version; html_url = release.url }
    }
}
