import XCTest
import Observation
import ContainerKit
@testable import AppCore

@MainActor
final class LiveStatsTests: XCTestCase {

    /// Stats whose CPU counter grows by 0.5 s of CPU per call.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var usec: Int64 = 1_000_000
        func next() -> Int64 { lock.withLock { usec += 500_000; return usec } }
    }

    func testUnchangedFullSeriesDoesNotNotifyObservers() async {
        let mock = MockCLI()
        mock.responder = { _ in
            Data("[{\"id\":\"web\",\"cpuUsageUsec\":0,\"memoryUsageBytes\":100,\"memoryLimitBytes\":1000,\"networkRxBytes\":0,\"networkTxBytes\":0,\"blockReadBytes\":0,\"blockWriteBytes\":0,\"numProcesses\":1}]".utf8)
        }
        let engine = CLIEngine(cli: mock, stream: CLIStream())
        let stats = LiveStats()
        for _ in 0...LiveStats.historyLength { await stats.sample(engine: engine, ids: ["web"]) }
        let changed = ChangeFlag()
        withObservationTracking { _ = stats.series } onChange: { changed.mark() }
        await stats.sample(engine: engine, ids: ["web"])
        XCTAssertFalse(changed.value)
        await stats.sample(engine: engine, ids: [])
        XCTAssertTrue(changed.value, "removal still notifies observers")
    }

    private final class ChangeFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var changed = false
        var value: Bool { lock.withLock { changed } }
        func mark() { lock.withLock { changed = true } }
    }

    func testSeriesAccumulatesAndForgetsStoppedContainers() async throws {
        let counter = Counter()
        let mock = MockCLI()
        mock.responder = { arguments in
            guard arguments.first == "stats", let id = arguments.last else { return Data("[]".utf8) }
            let json = """
            [{"id":"\(id)","cpuUsageUsec":\(counter.next()),"memoryUsageBytes":104857600,\
            "memoryLimitBytes":1073741824,"networkRxBytes":0,"networkTxBytes":0,\
            "blockReadBytes":0,"blockWriteBytes":0,"numProcesses":1}]
            """
            return Data(json.utf8)
        }
        let engine = CLIEngine(cli: mock, stream: CLIStream())
        let stats = LiveStats()

        await stats.sample(engine: engine, ids: ["web"])
        XCTAssertEqual(stats.series["web"]?.cpu.count, 0, "the first sample only sets a baseline")
        XCTAssertEqual(stats.series["web"]?.memoryUsage, 104_857_600)

        try await Task.sleep(for: .milliseconds(100))
        await stats.sample(engine: engine, ids: ["web"])
        let cpu = try XCTUnwrap(stats.series["web"]?.latestCPU)
        XCTAssertGreaterThan(cpu, 0)
        XCTAssertEqual(stats.series["web"]?.memoryFraction ?? 0, 0.0977, accuracy: 0.001)

        await stats.sample(engine: engine, ids: [])
        XCTAssertNil(stats.series["web"], "stopped containers are dropped")
    }
}
