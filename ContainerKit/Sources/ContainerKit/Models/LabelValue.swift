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
