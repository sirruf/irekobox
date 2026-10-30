import XCTest
import ContainerKit
@testable import AppCore

final class StatsHistoryTests: XCTestCase {

    private func stats(cpu: Int64 = 0, memory: Int64 = 100, rx: Int64 = 0, tx: Int64 = 0,
                       read: Int64 = 0, write: Int64 = 0) -> ContainerStats {
        ContainerStats(id: "web", cpuUsageUsec: cpu, memoryUsageBytes: memory, memoryLimitBytes: 1000,
                       networkRxBytes: rx, networkTxBytes: tx, blockReadBytes: read, blockWriteBytes: write,
                       numProcesses: 3)
    }

    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    func testRatesAreDeltasOverElapsedTime() throws {
        var history = StatsHistory()
        history.add(stats(), at: t0)
        XCTAssertTrue(history.points.isEmpty, "the first sample has nothing to compare against")
        XCTAssertEqual(history.latest?.numProcesses, 3)

        // 2 s later: 1 s of CPU time (50%), 4 KB in, 2 KB out, 8 KB read, 1 KB written.
        history.add(stats(cpu: 1_000_000, memory: 300, rx: 4096, tx: 2048, read: 8192, write: 1024),
                    at: t0.addingTimeInterval(2))
        let point = try XCTUnwrap(history.last)
        XCTAssertEqual(point.cpuPercent, 50, accuracy: 0.001)
        XCTAssertEqual(point.memoryBytes, 300)
        XCTAssertEqual(point.networkInPerSecond, 2048)
        XCTAssertEqual(point.networkOutPerSecond, 1024)
        XCTAssertEqual(point.diskReadPerSecond, 4096)
        XCTAssertEqual(point.diskWritePerSecond, 512)
    }

    func testCounterResetReadsAsZeroNotNegative() throws {
        var history = StatsHistory()
        history.add(stats(rx: 10_000), at: t0)
        history.add(stats(rx: 50), at: t0.addingTimeInterval(1))
        XCTAssertEqual(try XCTUnwrap(history.last).networkInPerSecond, 0)
    }

    func testKeepsOnlyTheWindow() {
        var history = StatsHistory()
        for second in stride(from: 0, through: 600, by: 2) {
            history.add(stats(cpu: Int64(second) * 1000), at: t0.addingTimeInterval(TimeInterval(second)))
        }
        let span = history.points.last!.time.timeIntervalSince(history.points.first!.time)
        XCTAssertLessThanOrEqual(span, StatsHistory.window)
        XCTAssertGreaterThan(span, StatsHistory.window - 4)
    }

    func testRateFormat() {
        XCTAssertEqual(Format.rate(0), "0 B/s")
        XCTAssertEqual(Format.rate(0.4), "0 B/s")
        XCTAssertTrue(Format.rate(1_500_000).hasSuffix("MB/s"))
    }

    func testNiceTicks() {
        XCTAssertEqual(StatsHistory.niceTicks(upTo: 400), [0, 200, 400])
        XCTAssertEqual(StatsHistory.niceTicks(upTo: 1024), [0, 1000])
        XCTAssertEqual(StatsHistory.niceTicks(upTo: 160_000), [0, 100_000])
        XCTAssertEqual(StatsHistory.niceTicks(upTo: 0), [0])
    }
}
