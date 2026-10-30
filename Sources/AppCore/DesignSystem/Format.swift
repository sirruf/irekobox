import Foundation

/// Formatting helpers shared across screens.
enum Format {
    /// Disk and transfer sizes, decimal units ("26.3 MB").
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func bytes(_ value: Int) -> String {
        bytes(Int64(value))
    }

    /// Memory sizes in binary units, the way they're configured: 1024 MB, not "1.07 GB".
    static func memory(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    /// Compact elapsed time in the user's language: "45s", "4m", "2h 14m",
    /// "3d 2h" (two largest units).
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let units: NSCalendar.Unit = total >= 86_400 ? [.day, .hour] : total >= 3600 ? [.hour, .minute]
            : total >= 60 ? [.minute] : [.second]
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = units
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: TimeInterval(total)) ?? "\(total)s"
    }

    // Cached formatters. `nonisolated(unsafe)` is safe here: they are only read
    // (never mutated) after construction, and Foundation's date formatters are
    // thread-safe for formatting.
    nonisolated(unsafe) private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoParserNoFraction = ISO8601DateFormatter()

    nonisolated(unsafe) private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        // "6d ago" in English; elsewhere the abbreviated style can drop the
        // "ago" (Russian shows a bare "-6 d"), so the short one.
        f.unitsStyle = Locale.current.language.languageCode == .english ? .abbreviated : .short
        return f
    }()

    static func date(fromISO iso: String) -> Date? {
        isoParser.date(from: iso) ?? isoParserNoFraction.date(from: iso)
    }

    /// Render an ISO-8601 timestamp string (as emitted by the `container` CLI)
    /// as a human-friendly relative time, e.g. "2h ago". Falls back to the first
    /// 19 characters of the raw string if it can't be parsed.
    static func relative(fromISO iso: String) -> String {
        guard let date = date(fromISO: iso) else { return String(iso.prefix(19)) }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// Absolute date and time for an ISO-8601 timestamp, e.g. "Oct 25, 2026 at 17:01".
    static func dateTime(fromISO iso: String) -> String {
        guard let date = date(fromISO: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
