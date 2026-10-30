import Foundation

/// `container` refuses a label whose value holds "=" (`--label k=a=b`), which
/// Docker allows. Such values are stored as `ib64:` + unpadded base64url and
/// read back transparently (`Container.Configuration.labels`). ComposeKit
/// writes the same format.
public enum LabelValue {
    static let prefix = "ib64:"

    /// The value as `container` accepts it.
    public static func encode(_ value: String) -> String {
        guard value.contains("=") else { return value }
        let base64 = Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return prefix + base64
    }

    /// The value as it was given.
    public static func decode(_ value: String) -> String {
        guard value.hasPrefix(prefix) else { return value }
        var base64 = String(value.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let text = String(data: data, encoding: .utf8) else { return value }
        return text
    }
}

/// `container network create` takes only lowercase DNS-style label keys
/// (`com.example.tier`, `a.b/c`); Docker takes any (`MyKey`, `my_key`).
/// Other keys are stored in that form and the originals kept in one label,
/// read back transparently (`Network.Configuration.labels`).
public enum LabelKey {
    static let originals = "com.irekobox.label-keys"

    /// `container`'s own rule (ResourceLabels.validateLabelKey).
    public static func isValid(_ key: String) -> Bool {
        guard !key.isEmpty, key.count <= 128 else { return false }
        let segment = #"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?"#
        let name = "\(segment)(?:\\.\(segment))*"
        return key.range(of: "^\(name)(?:/\(name))*$", options: .regularExpression) != nil
    }

    /// The labels as `container` accepts them.
    public static func encode(_ labels: [String: String]) -> [String: String] {
        guard labels.keys.contains(where: { !isValid($0) }) else { return labels }
        var result = labels.filter { isValid($0.key) }
        var originals: [String: String] = [:]
        for key in labels.keys.sorted() where !isValid(key) {
            var stored = normalized(key)
            if result[stored] != nil || !isValid(stored) { stored = "label-\(hash(key))" }
            result[stored] = labels[key]
            originals[stored] = key
        }
        if let data = try? JSONEncoder().encode(originals) {
            result[Self.originals] = String(decoding: data, as: UTF8.self)
        }
        return result
    }

    /// The labels as they were given.
    public static func decode(_ labels: [String: String]) -> [String: String] {
        guard let text = labels[originals],
              let names = try? JSONDecoder().decode([String: String].self, from: Data(text.utf8)) else { return labels }
        var result = labels
        result[originals] = nil
        for (stored, original) in names {
            guard let value = result.removeValue(forKey: stored) else { continue }
            result[original] = value
        }
        return result
    }

    /// `My_Key` → `my-key`: lowercase, other characters to `-`, each part
    /// trimmed to start and end with a letter or digit.
    static func normalized(_ key: String) -> String {
        let mapped = String(key.lowercased().map { ($0.isASCII && ($0.isLetter || $0.isNumber)) || "./".contains($0) ? $0 : "-" })
        return mapped.split(separator: "/", omittingEmptySubsequences: false).map { path in
            path.split(separator: ".", omittingEmptySubsequences: false).map { part in
                let trimmed = part.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                return trimmed.isEmpty ? "x" : trimmed
            }.joined(separator: ".")
        }.joined(separator: "/")
    }

    private static func hash(_ key: String) -> String {
        let value = key.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return String(String(value, radix: 16).prefix(10))
    }
}
