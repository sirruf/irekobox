import XCTest
@testable import AppCore

@MainActor
final class LogContextTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 10_000)

    private func states(api running: Bool = true, health: String? = nil) -> [String: LogContext.State] {
        ["shop-web-1": .init(name: "web", running: true),
         "shop-api-1": .init(name: "api", running: running, health: health)]
    }

    func testFirstSightIsNoChange() {
        var context = LogContext(followed: ["shop-web-1"])
        XCTAssertTrue(context.update(states(api: false), at: t0).isEmpty)
        XCTAssertTrue(context.events.isEmpty)
    }

    func testOwnStopBecomesANote() {
        var context = LogContext(followed: ["shop-api-1"])
        _ = context.update(states(), at: t0)
        let notes = context.update(states(api: false), at: t0.addingTimeInterval(1))
        XCTAssertEqual(notes.map(\.text), ["api stopped"])
    }

    func testNeighbourRestartExplainsTheNextErrorOnce() throws {
        var context = LogContext(followed: ["shop-web-1"])
        _ = context.update(states(), at: t0)
        XCTAssertTrue(context.update(states(api: false), at: t0.addingTimeInterval(1)).isEmpty,
                      "a neighbour's change is no note by itself")
        _ = context.update(states(), at: t0.addingTimeInterval(4))

        XCTAssertNil(context.explain("GET / 200", level: .info, at: t0.addingTimeInterval(5)))
        let note = try XCTUnwrap(context.explain("upstream timed out (api:3000)", level: .error,
                                                 at: t0.addingTimeInterval(5)))
        XCTAssertTrue(note.text.hasPrefix("api was restarting at"))
        XCTAssertEqual(note.note.containerID, "shop-api-1")
        XCTAssertEqual(note.note.linkTitle, "Show api logs")
        XCTAssertNil(context.explain("upstream timed out (api:3000)", level: .error, at: t0.addingTimeInterval(6)),
                     "explained once")
    }

    func testRestartBetweenTwoLooksIsSeenByItsStartDate() throws {
        var context = LogContext(followed: ["shop-web-1"])
        var before = states()
        before["shop-api-1"]?.started = t0.addingTimeInterval(-3600)
        _ = context.update(before, at: t0)
        var after = states()
        after["shop-api-1"]?.started = t0.addingTimeInterval(2)
        _ = context.update(after, at: t0.addingTimeInterval(4))
        let note = try XCTUnwrap(context.explain("[error] open() failed", level: .error, at: t0.addingTimeInterval(3)))
        XCTAssertTrue(note.text.hasPrefix("api was restarting at"))
    }

    func testOldChangeExplainsOnlyErrorsThatNameIt() {
        var context = LogContext(followed: ["shop-web-1"])
        _ = context.update(states(), at: t0)
        _ = context.update(states(api: false), at: t0.addingTimeInterval(1))
        let later = t0.addingTimeInterval(120)
        XCTAssertNil(context.explain("disk full", level: .error, at: later))
        let note = context.explain("connect to api failed", level: .error, at: later)
        XCTAssertEqual(note?.text.contains("has been stopped since"), true)
    }

    func testUnhealthyNeighbour() {
        var context = LogContext(followed: ["shop-web-1"])
        _ = context.update(states(health: "healthy"), at: t0)
        _ = context.update(states(health: "unhealthy"), at: t0.addingTimeInterval(1))
        let note = context.explain("WARN slow response", level: .warning, at: t0.addingTimeInterval(3))
        XCTAssertEqual(note?.text.contains("failing its health check"), true)
    }

    func testErrorBeforeTheChangeIsSeenIsExplainedLate() {
        let model = LogViewerModel()
        model.follow(["shop-web-1"])
        var before = states()
        before["shop-api-1"]?.started = t0.addingTimeInterval(-3600)
        model.observe(before, at: t0)
        model.ingest(["[error] connect() failed"], at: t0.addingTimeInterval(3))
        XCTAssertNil(model.buffer.entries.last?.note)
        var after = states()
        after["shop-api-1"]?.started = t0.addingTimeInterval(2)
        model.observe(after, at: t0.addingTimeInterval(5))
        XCTAssertEqual(model.buffer.entries.last?.note?.containerID, "shop-api-1")
    }

    func testNotesThatTrimTheBufferRecountRetainedProblems() {
        let model = LogViewerModel(capacity: 2)
        model.follow(["shop-api-1"])
        model.observe(states(), at: t0)
        model.ingest(["ERROR old", "INFO newer"], at: t0)
        XCTAssertEqual(model.problemCount, 1)
        model.observe(states(api: false), at: t0.addingTimeInterval(1))
        XCTAssertEqual(model.buffer.entries.count, 2)
        XCTAssertEqual(model.problemCount, 0, "the note evicted the oldest error")
    }

    func testModelAddsExplanationAfterTheError() async throws {
        let model = LogViewerModel()
        model.follow(["shop-web-1"])
        model.observe(states(), at: t0)
        model.observe(states(api: false), at: t0.addingTimeInterval(1))
        model.ingest(["GET / 200", "ERROR upstream api unreachable"], at: t0.addingTimeInterval(2))
        XCTAssertEqual(model.buffer.entries.count, 3)
        XCTAssertNotNil(model.buffer.entries.last?.note)
        XCTAssertEqual(model.problemCount, 1)

        model.filter.warningsOnly = true
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.visibleEntries.count, 2, "the note stays with the error")
        XCTAssertEqual(model.problemCount, 1, "notes aren't problems")
    }
}
