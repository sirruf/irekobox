import Foundation

/// Registries reached over plain HTTP, as Docker treats them: loopback hosts
/// always, plus `insecure-registries` from `~/.docker/daemon.json` (exact
/// `host` or `host:port` entries; CIDR ranges aren't matched).
public enum InsecureRegistries {
    public static var daemonConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".docker/daemon.json")
    }

    /// The `insecure-registries` entries of a daemon.json; none if it's absent.
    public static func listed(in file: URL = daemonConfig) -> [String] {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object["insecure-registries"] as? [String] ?? []
    }

    public static func isInsecure(host: String, listed: [String]) -> Bool {
        let name = hostName(host)
        if name == "localhost" || name == "::1" || name.hasPrefix("127.") { return true }
        return listed.contains { $0 == host || $0 == name }
    }

    /// `--scheme http` for a registry host that must be reached over HTTP.
    public static func schemeArguments(host: String, listed: [String] = listed()) -> [String] {
        isInsecure(host: host, listed: listed) ? ["--scheme", "http"] : []
    }

    /// `--scheme http` for an image whose registry must be reached over HTTP.
    public static func schemeArguments(reference: String, listed: [String] = listed()) -> [String] {
        guard let registry = ImageReference(reference)?.registry else { return [] }
        return schemeArguments(host: registry, listed: listed)
    }

    /// `server:5000` → `server`, `[::1]:5000` → `::1`.
    static func hostName(_ host: String) -> String {
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            return String(host[host.index(after: host.startIndex)..<close])
        }
        if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") {
            return String(host[..<colon])
        }
        return host
    }
}
