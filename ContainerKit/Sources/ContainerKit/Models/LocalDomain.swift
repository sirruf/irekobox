import Foundation

/// Names under `container`'s default DNS domain (`container system dns
/// create <domain>` plus `[dns] domain` in config.toml). Its DNS server
/// (127.0.0.1:2053, reached from the Mac through /etc/resolver) answers
/// `<container>.<domain>` and every network alias as written, with the
/// container's own address, so a service needs no published port.
public enum LocalDomain {
    /// `domain = "…"` in the `[dns]` table of `container system property ls`.
    public static func parse(properties: String) -> String? {
        var inDNS = false
        for raw in properties.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inDNS = line == "[dns]"; continue }
            guard inDNS, line.hasPrefix("domain") else { continue }
            let value = line.split(separator: "=", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if let value, !value.isEmpty { return value }
        }
        return nil
    }

    /// A DNS label: lowercase letters, digits and hyphens.
    public static func label(_ text: String) -> String {
        let mapped = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// `web.shop.test` for service `web` of compose project `shop`.
    public static func serviceName(service: String, project: String, domain: String) -> String? {
        let service = label(service), project = label(project)
        guard !service.isEmpty, !project.isEmpty else { return nil }
        return "\(service).\(project).\(domain)"
    }

    /// The name `container` gives every container: `<name>.<domain>`.
    public static func containerName(_ name: String, domain: String) -> String {
        "\(name).\(domain)"
    }
}
