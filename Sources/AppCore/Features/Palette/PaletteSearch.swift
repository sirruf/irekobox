import Foundation

/// Something the command palette can find and do.
struct PaletteItem: Identifiable {
    enum Kind: Int, Comparable {
        case container, image, section, action
        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .container: return String(localized: "Containers")
            case .image: return String(localized: "Images")
            case .section: return String(localized: "Go to")
            case .action: return String(localized: "Actions")
            }
        }
    }

    let id: String
    let kind: Kind
    let title: String
    var subtitle: String = ""
    var systemImage: String
    /// Extra words that should match (image, ports, project…).
    var keywords: String = ""
    let perform: @MainActor () -> Void
}

/// Fuzzy ranking: every query character must appear in order; earlier,
/// consecutive and word-start matches in the title score higher.
enum PaletteSearch {
    static func rank(_ items: [PaletteItem], query: String, limit: Int = 30) -> [PaletteItem] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else {
            return Array(items.sorted { ($0.kind, $0.title) < ($1.kind, $1.title) }.prefix(limit))
        }
        // Typed with the Russian layout still on (Cyrillic letters for "redis")? Try both.
        let queries = Set([query, latinLayout(query)])
        let scored = items.compactMap { item -> (PaletteItem, Int)? in
            let title = item.title.lowercased()
            let other = (item.subtitle + " " + item.keywords).lowercased()
            let scores = queries.flatMap { query in
                // Scattered letters only count in the title: across a long
                // reference ("docker.io/library/…") they match almost anything.
                [score(query, in: title), score(query, in: other, fuzzy: false).map { $0 / 2 }]
            }
            guard let best = scores.compactMap({ $0 }).max() else { return nil }
            return (item, best)
        }
        let ranked = scored
            .sorted { lhs, rhs in
                lhs.1 != rhs.1 ? lhs.1 > rhs.1 : (lhs.0.kind, lhs.0.title) < (rhs.0.kind, rhs.0.title)
            }
            .prefix(limit)
            .map(\.0)
        // One block per kind, blocks ordered by their best match.
        var kinds: [PaletteItem.Kind] = []
        for item in ranked where !kinds.contains(item.kind) { kinds.append(item.kind) }
        return kinds.flatMap { kind in ranked.filter { $0.kind == kind } }
    }

    private static let russianToLatin: [Character: Character] = {
        // The Russian keyboard rows, as escapes to keep the source ASCII.
        let russian = Array("\u{0439}\u{0446}\u{0443}\u{043A}\u{0435}\u{043D}\u{0433}\u{0448}\u{0449}\u{0437}\u{0445}\u{044A}\u{0444}\u{044B}\u{0432}\u{0430}\u{043F}\u{0440}\u{043E}\u{043B}\u{0434}\u{0436}\u{044D}\u{044F}\u{0447}\u{0441}\u{043C}\u{0438}\u{0442}\u{044C}\u{0431}\u{044E}")
        let latin = Array("qwertyuiop[]asdfghjkl;'zxcvbnm,.")
        return Dictionary(uniqueKeysWithValues: zip(russian, latin))
    }()

    /// The same keys pressed on a US layout: the Russian keys of "redis" → "redis".
    static func latinLayout(_ text: String) -> String {
        String(text.map { russianToLatin[$0] ?? $0 })
    }

    /// `nil` when `query` isn't a subsequence of `text`.
    static func score(_ query: String, in text: String, fuzzy: Bool = true) -> Int? {
        guard !text.isEmpty else { return nil }
        if text == query { return 1000 }
        if text.hasPrefix(query) { return 800 - text.count }
        if let range = text.range(of: query) {
            let atWordStart = range.lowerBound == text.startIndex
                || !text[text.index(before: range.lowerBound)].isLetter
            return (atWordStart ? 600 : 400) - text.distance(from: text.startIndex, to: range.lowerBound)
        }
        guard fuzzy else { return nil }
        // Subsequence with gaps.
        var score = 0
        var textIndex = text.startIndex
        var previousMatch: String.Index?
        for character in query {
            guard let found = text[textIndex...].firstIndex(of: character) else { return nil }
            score += 10
            if let previous = previousMatch, text.index(after: previous) == found { score += 15 }
            if found == text.startIndex || !text[text.index(before: found)].isLetter { score += 10 }
            previousMatch = found
            textIndex = text.index(after: found)
        }
        return score
    }
}
