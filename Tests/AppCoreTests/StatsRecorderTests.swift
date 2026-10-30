import XCTest
import ContainerKit
@testable import AppCore

@MainActor
final class StatsRecorderTests: XCTestCase {
    private func stats(cpu: Int64, memory: Int64 = 100) -> ContainerStats {
        ContainerStats(id: "web", cpuUsageUsec: cpu, memoryUsageBytes: memory, memoryLimitBytes: 1000,
                       networkRxBytes: 0, networkTxBytes: 0, blockReadBytes: 0, blockWriteBytes: 0,
                       numProcesses: 1)
    }

    func testAveragedIntoBuckets() {
        let base = Date(timeIntervalSinceReferenceDate: 3000)   // a bucket boundary for 300 s
        let points = (0..<40).map { index in
            StatsHistory.Point(time: base.addingTimeInterval(Double(index) * 15),
                               cpuPercent: index < 20 ? 10 : 30, memoryBytes: 100,
                               networkInPerSecond: 0, networkOutPerSecond: 0,
                               diskReadPerSecond: 0, diskWritePerSecond: 0)
        }
        let averaged = StatsHistory.averaged(points, bucket: 300)
        XCTAssertEqual(averaged.map(\.cpuPercent), [10, 30])
        XCTAssertEqual(averaged.first?.time, base.addingTimeInterval(150))
    }

    func testRecordsKeepsRangeAndForgetsRemoved() {
        let recorder = StatsRecorder()
        let now = Date()
        for step in 0..<10 {
            let time = now.addingTimeInterval(Double(step - 9) * 600)   // every 10 minutes, the last at now
            recorder.record([("web", stats(cpu: Int64(step) * 60_000_000))], existing: ["web"], at: time)
        }
        XCTAssertEqual(recorder.points("web", range: 3600, now: now).count, 7)
        XCTAssertEqual(recorder.points("web", range: 86_400, now: now).count, 9)

        recorder.record([], existing: [], at: now)
        XCTAssertTrue(recorder.points("web", range: 3600, now: now).isEmpty)
    }
}
