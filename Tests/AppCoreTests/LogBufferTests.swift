import XCTest
@testable import AppCore

final class LogBufferTests: XCTestCase {

    func testByteLimitKeepsNewestWholeUTF8AndBoundsNotes() {
        var buffer = LogBuffer(capacity: 100, byteCapacity: 12)
        buffer.append(["aaaaaa", "bbbbbb", "cccccc"])
        XCTAssertEqual(buffer.entries.map(\.text), ["bbbbbb", "cccccc"])
        buffer.append([String(repeating: "界", count: 20)])
        XCTAssertLessThanOrEqual(buffer.entries.reduce(0) { $0 + $1.text.utf8.count }, 13)
        XCTAssertEqual(buffer.entries.last?.text, "界界界界")
        XCTAssertFalse(buffer.entries.last?.text.contains("�") ?? true)
        for _ in 0..<100 { buffer.appendNote("note", LogNote()) }
        XCTAssertLessThanOrEqual(buffer.entries.reduce(0) { $0 + $1.text.utf8.count }, 13)
        buffer.clear()
        buffer.append(["after clear"])
        XCTAssertEqual(buffer.entries.map(\.text), ["after clear"])
    }

    func testPendingBacklogIsBoundedByLinesAndBytes() {
        var pending = LogPending(capacity: 10, byteCapacity: 30)
        for index in 0..<1000 { pending.append("\(index)界界界") }
        XCTAssertLessThanOrEqual(pending.lines.count, 11)
        XCTAssertLessThanOrEqual(pending.lines.reduce(0) { $0 + $1.utf8.count }, 33)
        XCTAssertEqual(pending.lines.last, "999界界界")
        pending.removeAll()
        pending.append("new")
        XCTAssertEqual(pending.lines, ["new"])
    }

    func testLevels() {
        XCTAssertEqual(LogBuffer.level(of: "ERROR FATAL: heap out of memory"), .error)
        XCTAssertEqual(LogBuffer.level(of: "level=error msg=boom"), .error)
        XCTAssertEqual(LogBuffer.level(of: "WARN  heap usage 231 MB"), .warning)
        XCTAssertEqual(LogBuffer.level(of: "[warning] slow query"), .warning)
        XCTAssertEqual(LogBuffer.level(of: "INFO consumer started"), .info)
        // Words, not substrings: "terror" and "warnings_total" stay info.
        XCTAssertEqual(LogBuffer.level(of: "terror metrics"), .info)
        XCTAssertEqual(LogBuffer.level(of: "errors_total 0"), .info)
    }

    func testAppendAssignsIncreasingIDs() {
        var buffer = LogBuffer(capacity: 10)
        let first = buffer.append(["a", "b"])
        let second = buffer.append(["c"])
        XCTAssertEqual(first.map(\.id), [0, 1])
        XCTAssertEqual(second.map(\.id), [2])
        XCTAssertEqual(buffer.entries.map(\.text), ["a", "b", "c"])
    }

    func testCapacityDropsOldestLines() {
        var buffer = LogBuffer(capacity: 100)
        for chunk in 0..<30 {
            buffer.append((0..<10).map { "line \(chunk * 10 + $0)" })
        }
        XCTAssertLessThanOrEqual(buffer.entries.count, 110)
        XCTAssertEqual(buffer.entries.last?.text, "line 299")
        XCTAssertGreaterThan(buffer.firstID, 0)
        XCTAssertEqual(buffer.entries.first?.id, buffer.firstID)
    }

    func testFilterAndMatchCount() {
        var buffer = LogBuffer()
        buffer.append(["INFO started", "WARN memory high", "ERROR out of memory, memory gone", "INFO done"])
        XCTAssertEqual(buffer.visible(LogFilter(warningsOnly: true)).map(\.text),
                       ["WARN memory high", "ERROR out of memory, memory gone"])
        let matching = buffer.visible(LogFilter(query: "MEMORY"))
        XCTAssertEqual(matching.count, 2)
        XCTAssertEqual(LogBuffer.matchCount("memory", in: matching), 3)
        XCTAssertEqual(LogBuffer.matchCount("", in: matching), 0)
    }

    func testClearKeepsIDsMonotonic() {
        var buffer = LogBuffer()
        buffer.append(["a", "b"])
        buffer.clear()
        XCTAssertTrue(buffer.entries.isEmpty)
        XCTAssertEqual(buffer.append(["c"]).first?.id, 2)
    }
}
