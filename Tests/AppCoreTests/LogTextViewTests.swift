import XCTest
import AppKit
@testable import AppCore

/// The NSTextView-backed log view, driven without a window.
@MainActor
final class LogTextViewTests: XCTestCase {

    private func makeView(_ model: LogViewerModel) -> (LogTextView.Coordinator, NSTextView) {
        let coordinator = LogTextView.Coordinator(model: model)
        let (scrollView, textView) = LogTextView.makeTextView()
        coordinator.attach(scrollView: scrollView, textView: textView)
        return (coordinator, textView)
    }

    func testAppendsOnlyNewLinesAndHonoursFilter() async throws {
        let model = LogViewerModel()
        model.showTimestamps = false
        let (coordinator, textView) = makeView(model)

        model.ingest(["one", "two"])
        coordinator.update()
        XCTAssertEqual(textView.string, "one\ntwo\n")

        model.ingest(["three"])
        coordinator.update()
        XCTAssertEqual(textView.string, "one\ntwo\nthree\n")

        model.filter.query = "t"
        try await Task.sleep(for: .milliseconds(350))
        coordinator.update()
        XCTAssertEqual(textView.string, "two\nthree\n")

        model.ingest(["four", "ten"])
        coordinator.update()
        XCTAssertEqual(textView.string, "two\nthree\nten\n")
    }

    func testTrimmedLinesLeaveTheText() {
        let model = LogViewerModel(capacity: 10)
        model.showTimestamps = false
        let (coordinator, textView) = makeView(model)
        for batch in 0..<10 {
            model.ingest((0..<5).map { "line \(batch * 5 + $0)" })
            coordinator.update()
        }
        let lines = textView.string.split(separator: "\n")
        XCTAssertEqual(lines.count, model.buffer.entries.count)
        XCTAssertEqual(lines.last, "line 49")
        XCTAssertEqual(lines.first.map(String.init), model.buffer.entries.first?.text)
    }

    /// 100k lines in 500-line batches (a chatty container at 100 ms flushes):
    /// the view stays bounded by the buffer and well within a frame budget per batch.
    func testHundredThousandLines() {
        let model = LogViewerModel(capacity: 50_000)
        let (coordinator, textView) = makeView(model)
        let line = String(repeating: "x", count: 80)
        let clock = ContinuousClock()
        var worst: Duration = .zero
        let total = clock.measure {
            for batch in 0..<200 {
                model.ingest((0..<500).map { "\(batch)-\($0) INFO \(line)" })
                let batchTime = clock.measure { coordinator.update() }
                worst = max(worst, batchTime)
            }
        }
        XCTAssertLessThanOrEqual(model.buffer.entries.count, 55_000)
        XCTAssertEqual(textView.string.split(separator: "\n").count, model.buffer.entries.count)
        print("100k lines: total \(total), worst batch \(worst)")
        XCTAssertLessThan(worst, .milliseconds(250), "a batch update must not stall the UI")
    }
}
