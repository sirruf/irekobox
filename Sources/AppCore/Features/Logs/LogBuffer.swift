import Foundation

/// One log line with the time it arrived and a guessed severity.
struct LogEntry: Identifiable, Equatable {
    enum Level: Int, Comparable {
        case info, warning, error
        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Monotonic; never reused, so views can tell what they already showed.
    let id: Int
    let time: Date
    let text: String
    let level: Level
    /// Set for a line the app adds (a restart, an explanation), not the container.
    var note: LogNote? = nil
}

/// A line the app adds to a log: what happened to a container, or why an
/// error probably happened. `containerID` links to that container's logs.
struct LogNote: Equatable {
    var containerID: String?
    var linkTitle: String?
}

/// What a log view shows.
struct LogFilter: Equatable {
    var query = ""
    var warningsOnly = false

    func matches(_ entry: LogEntry) -> Bool {
        // Notes explain the lines around them, so they stay with any severity.
        if warningsOnly && entry.level < .warning && entry.note == nil { return false }
        guard !query.isEmpty else { return true }
        return entry.text.range(of: query, options: .caseInsensitive) != nil
    }
}

/// A bounded log: appends are cheap, the oldest lines go once `capacity` is
/// exceeded (trimmed in chunks so appends stay amortized O(1)).
struct LogBuffer {
    let capacity: Int
    private(set) var entries: [LogEntry] = []
    private var nextID = 0

    init(capacity: Int = 50_000) {
        self.capacity = max(1, capacity)
    }

    /// ID of the oldest line still kept (everything below was dropped).
    var firstID: Int { entries.first?.id ?? nextID }

    @discardableResult
    mutating func append(_ lines: [String], at time: Date = Date()) -> [LogEntry] {
        let added = lines.map { line -> LogEntry in
            defer { nextID += 1 }
            return LogEntry(id: nextID, time: time, text: line, level: Self.level(of: line))
        }
        entries.append(contentsOf: added)
        // Trim with slack so we don't shift the array on every append.
        if entries.count > capacity + capacity / 10 {
            entries.removeFirst(entries.count - capacity)
        }
        return added
    }

    /// Add a line of the app's own after the container's output.
    @discardableResult
    mutating func appendNote(_ text: String, _ note: LogNote, at time: Date = Date()) -> LogEntry {
        let entry = LogEntry(id: nextID, time: time, text: text, level: .info, note: note)
        nextID += 1
        entries.append(entry)
        return entry
    }

    mutating func clear() {
        entries.removeAll()
    }

    func visible(_ filter: LogFilter) -> [LogEntry] {
        filter == LogFilter() ? entries : entries.filter(filter.matches)
    }

    /// Occurrences of `query` across the visible lines.
    static func matchCount(_ query: String, in entries: [LogEntry]) -> Int {
        guard !query.isEmpty else { return 0 }
        return entries.reduce(0) { count, entry in
            var found = 0
            var range = entry.text.startIndex..<entry.text.endIndex
            while let match = entry.text.range(of: query, options: .caseInsensitive, range: range) {
                found += 1
                range = match.upperBound..<entry.text.endIndex
            }
            return count + found
        }
    }

    // MARK: - Severity

    private static let errorWords: Set<String> = ["error", "err", "fatal", "panic", "critical", "crit", "exception", "emerg", "alert"]
    private static let warningWords: Set<String> = ["warn", "warning"]

    /// Severity from the words in a line ("ERROR", "level=warn", "[W]" aside).
    static func level(of line: String) -> LogEntry.Level {
        var sawWarning = false
        for word in line.lowercased().split(whereSeparator: { !$0.isLetter }) {
            if errorWords.contains(String(word)) { return .error }
            if warningWords.contains(String(word)) { sawWarning = true }
        }
        return sawWarning ? .warning : .info
    }
}
