import Foundation
import Yams

/// Adds a cluster's own kubeconfig to the default one (~/.kube/config), the
/// way kubectl merges files: its context renamed `irekobox-<name>`,
/// entries with the same name replaced, the current context left as it was.
enum Kubeconfig {
    static func contextName(for cluster: String) -> String { "irekobox-\(cluster)" }

    struct MergeError: LocalizedError {
        let errorDescription: String?
    }

    /// `base` is the default file's text (empty if there is none); `cluster`
    /// the cluster's file. Returns the merged text.
    static func merge(_ cluster: String, file: String, into base: String) throws -> String {
        let name = contextName(for: cluster)
        guard var added = try Yams.load(yaml: file) as? [String: Any] else {
            throw MergeError(errorDescription: String(localized: "The cluster's kubeconfig can't be read."))
        }
        var config = (try Yams.load(yaml: base) as? [String: Any]) ?? [:]
        // Rename the cluster's context, cluster and user, so nothing in the
        // default file with the same short name ("dev") is touched.
        var renamed: [String: String] = [:]
        for key in ["clusters", "users", "contexts"] {
            added[key] = (added[key] as? [[String: Any]] ?? []).map { entry in
                var entry = entry
                if let old = entry["name"] as? String {
                    renamed["\(key):\(old)"] = name
                    entry["name"] = name
                }
                return entry
            }
        }
        added["contexts"] = (added["contexts"] as? [[String: Any]] ?? []).map { entry in
            var entry = entry
            var context = entry["context"] as? [String: Any] ?? [:]
            if let old = context["cluster"] as? String { context["cluster"] = renamed["clusters:\(old)"] ?? old }
            if let old = context["user"] as? String { context["user"] = renamed["users:\(old)"] ?? old }
            entry["context"] = context
            return entry
        }
        for key in ["clusters", "users", "contexts"] {
            let incoming = added[key] as? [[String: Any]] ?? []
            let names = Set(incoming.compactMap { $0["name"] as? String })
            let kept = (config[key] as? [[String: Any]] ?? []).filter { !names.contains($0["name"] as? String ?? "") }
            config[key] = kept + incoming
        }
        config["apiVersion"] = config["apiVersion"] ?? "v1"
        config["kind"] = config["kind"] ?? "Config"
        if (config["current-context"] as? String ?? "").isEmpty { config["current-context"] = name }
        return try Yams.dump(object: config, sortKeys: true)
    }

    static var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".kube/config")
    }

    /// Whether the default file already has the cluster's context.
    static func isAdded(_ cluster: String) -> Bool {
        guard let text = try? String(contentsOf: defaultFile, encoding: .utf8),
              let config = try? Yams.load(yaml: text) as? [String: Any] else { return false }
        return (config["contexts"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == contextName(for: cluster) }
    }

    /// Merge into ~/.kube/config, keeping the previous file next to it.
    static func add(_ cluster: String, from path: String) throws {
        let file = try String(contentsOfFile: path, encoding: .utf8)
        let target = defaultFile
        let base = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        let merged = try merge(cluster, file: file, into: base)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !base.isEmpty {
            try base.write(to: target.deletingLastPathComponent().appending(path: "config.before-irekobox"),
                           atomically: true, encoding: .utf8)
        }
        try merged.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}
