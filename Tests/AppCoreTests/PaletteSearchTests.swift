import XCTest
@testable import AppCore

@MainActor
final class PaletteSearchTests: XCTestCase {

    private func item(_ title: String, _ kind: PaletteItem.Kind = .container, keywords: String = "") -> PaletteItem {
        PaletteItem(id: title, kind: kind, title: title, systemImage: "circle", keywords: keywords, perform: {})
    }

    func testExactAndPrefixWin() {
        let items = [item("redis-dev"), item("cache", keywords: "redis:7-alpine"), item("red"), item("rapid-edit")]
        let ranked = PaletteSearch.rank(items, query: "red").map(\.title)
        XCTAssertEqual(ranked.first, "red")
        XCTAssertEqual(ranked[1], "redis-dev")
        XCTAssertTrue(ranked.contains("cache"), "matches through keywords")
        XCTAssertTrue(ranked.contains("rapid-edit"), "r…e…d as a scattered subsequence")
        XCTAssertLessThan(ranked.firstIndex(of: "cache")!, ranked.firstIndex(of: "rapid-edit")!,
                          "a substring in keywords beats a scattered subsequence in the title")
    }

    func testSubsequenceAndNonMatches() {
        XCTAssertNotNil(PaletteSearch.score("rdv", in: "redis-dev"))
        XCTAssertNil(PaletteSearch.score("xyz", in: "redis-dev"))
        XCTAssertNil(PaletteSearch.score("ved", in: "redis-dev"), "order matters")
    }

    func testWordStartBeatsMiddle() throws {
        let start = try XCTUnwrap(PaletteSearch.score("dev", in: "redis-dev"))
        let middle = try XCTUnwrap(PaletteSearch.score("dev", in: "abdevx"))
        XCTAssertGreaterThan(start, middle)
    }

    func testEmptyQueryListsByKind() {
        let items = [item("Run Image…", .action), item("web", .container), item("nginx", .image)]
        XCTAssertEqual(PaletteSearch.rank(items, query: "").map(\.title), ["web", "nginx", "Run Image…"])
    }

    func testFindsTextTypedWithTheRussianLayout() {
        XCTAssertEqual(PaletteSearch.latinLayout("\u{043A}\u{0443}\u{0432}\u{0448}\u{044B}"), "redis")
        let items = [item("redis-dev"), item("nginx")]
        XCTAssertEqual(PaletteSearch.rank(items, query: "\u{043A}\u{0443}\u{0432}\u{0448}\u{044B}").map(\.title), ["redis-dev"])
    }

    func testResultsStayGroupedByKind() {
        let items = [
            PaletteItem(id: "c1", kind: .container, title: "api", systemImage: "x", perform: {}),
            PaletteItem(id: "a1", kind: .action, title: "apiary", systemImage: "x", perform: {}),
            PaletteItem(id: "c2", kind: .container, title: "rapid-api", systemImage: "x", perform: {}),
        ]
        let kinds = PaletteSearch.rank(items, query: "api").map(\.kind)
        XCTAssertEqual(kinds, [.container, .container, .action])
    }

    func testLayoutFallbackPrefersTheExactName() {
        XCTAssertEqual(PaletteSearch.latinLayout("\u{0448}\u{0438}-\u{0444}\u{0437}\u{0448}"), "ib-api")
        let items = [item("ib-alpine-tmp"), item("ib-api")]
        XCTAssertEqual(PaletteSearch.rank(items, query: "\u{0448}\u{0438}-\u{0444}\u{0437}\u{0448}").first?.title, "ib-api")
    }

    func testDetailsNeedAWholeSubstring() {
        let items = [item("redis:7-alpine", .image), item("alpine:latest", .image, keywords: "docker.io/library/alpine:latest")]
        XCTAssertEqual(PaletteSearch.rank(items, query: "redis").map(\.title), ["redis:7-alpine"])
        XCTAssertEqual(PaletteSearch.rank(items, query: "library").count, 1, "substring of a reference still matches")
    }
}
