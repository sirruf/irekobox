import XCTest
import ContainerKit
@testable import AppCore

@MainActor
final class LogViewerModelTests: XCTestCase {

    func testFilterChangesRebuildAndRecount() async throws {
        let model = LogViewerModel()
        model.ingest(["INFO start", "WARN memory high", "ERROR out of memory"])
        let generation = model.generation

        model.filter.query = "memory"
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.matchCount, 2)
        XCTAssertGreaterThan(model.generation, generation)

        model.filter.warningsOnly = true
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.visibleEntries.map(\.text), ["WARN memory high", "ERROR out of memory"])

        // New matching lines add to the count without a rebuild.
        let before = model.generation
        model.ingest(["WARN memory again"])
        XCTAssertEqual(model.matchCount, 3)
        XCTAssertEqual(model.generation, before)
    }

    func testSearchDebouncesAndOnlyAppliesLatestVersion() async throws {
        let model = LogViewerModel()
        model.ingest(["alpha", "beta", "alphabet"])
        let before = model.generation
        model.filter.query = "alpha"
        XCTAssertEqual(model.generation, before, "typing does not rebuild the text synchronously")
        model.filter.query = "beta"
        model.ingest(["beta arrived during search"])
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.visibleEntries.map(\.text), ["beta", "beta arrived during search"])
        XCTAssertEqual(model.matchCount, 2)
        XCTAssertEqual(model.generation, before + 1)
        model.filter.query = "alpha"
        model.clear()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(model.visibleEntries.isEmpty, "a stale search must not restore cleared lines")
        XCTAssertEqual(model.matchCount, 0)
    }

    func testStreamFlushesWhileOpenAndFlushesTheLastBatch() async throws {
        let (lines, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let model = LogViewerModel()
        let task = Task { await model.stream(lines: lines, flushEvery: .milliseconds(20)) }
        continuation.yield("first")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.buffer.entries.map(\.text), ["first"])
        continuation.yield("last")
        continuation.finish()
        await task.value
        XCTAssertEqual(model.buffer.entries.map(\.text), ["first", "last"])
    }

    func testUnseenCountsOnlyWhilePaused() {
        let model = LogViewerModel()
        model.ingest(["a"])
        XCTAssertEqual(model.unseen, 0)

        model.isFollowing = false
        model.ingest(["b", "c"])
        XCTAssertEqual(model.unseen, 2)

        model.isFollowing = true
        XCTAssertEqual(model.unseen, 0)
    }

    func testVisibleTextHonoursTimestamps() throws {
        let model = LogViewerModel()
        let time = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T10:11:12Z"))
        model.ingest(["hello"], at: time)
        model.showTimestamps = false
        XCTAssertEqual(model.visibleText(), "hello")
        model.showTimestamps = true
        XCTAssertTrue(model.visibleText().hasSuffix("  hello"))
    }

    func testClearEmptiesTheView() {
        let model = LogViewerModel()
        model.ingest(["a", "b"])
        model.clear()
        XCTAssertTrue(model.visibleEntries.isEmpty)
    }

    // MARK: - Streaming

    /// A stand-in `container` that prints the given script output for `logs`.
    private func fakeCLI(_ script: String) throws -> CLIEngine {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ib-fake-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(script)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return CLIEngine(cli: MockCLI(), stream: CLIStream(binaryPath: url.path))
    }

    func testStreamCollectsLinesUntilTheProcessEnds() async throws {
        let engine = try fakeCLI("echo one; echo two; printf three")
        let model = LogViewerModel()
        await model.stream(engine: engine, id: "web", flushEvery: .milliseconds(10))
        XCTAssertEqual(model.buffer.entries.map(\.text), ["one", "two", "three"])
        XCTAssertNil(model.streamError)
    }

    func testStreamFailureIsReported() async throws {
        let engine = try fakeCLI("echo partial; echo 'container not found' >&2; exit 1")
        let model = LogViewerModel()
        await model.stream(engine: engine, id: "ghost", flushEvery: .milliseconds(10))
        XCTAssertEqual(model.buffer.entries.map(\.text), ["partial"])
        XCTAssertEqual(model.streamError, "container not found")
    }
}
