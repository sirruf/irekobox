import SwiftUI

/// Brand constants — name, version, and the signature gradient.
public enum Brand {
    public static let name = "Irekobox"
    public static var tagline: String { String(localized: "A native UI for Apple containers") }
    /// The bundle's version; the SwiftPM build has no Info.plist values.
    public static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    public static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    public static let copyright = "© 2026 Artem Kolesnikov"

    /// Public addresses. The website is the stable one: the repository may
    /// move to an organization later (GitHub redirects the old links).
    public static let website = URL(string: "https://irekobox.com")!
    public static let source = URL(string: "https://github.com/sirruf/irekobox")!
    public static let issues = URL(string: "https://github.com/sirruf/irekobox/issues")!

    /// Primary brand color (also DS.accent).
    public static let primary = Color(red: 0.33, green: 0.40, blue: 0.96)
    public static let secondary = Color(red: 0.56, green: 0.30, blue: 0.93)

    public static var gradient: LinearGradient {
        LinearGradient(colors: [primary, secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
