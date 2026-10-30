import XCTest
import ContainerKit
@testable import DockerAPIKit

private final class LogEngine: DockerBackend, @unchecked Sendable {
    var containers: [Container]
    var lines: [String] = []
    var stats: [ContainerStats] = []
    var logStream: (@Sendable (Bool) -> AsyncThrowingStream<String, Error>)?
    var listed: (@Sendable (Int) -> [Container])?
    private var lists = 0
    var listCount: Int { lock.withLock { lists } }
    private var statsIndex = 0
    private let lock = NSLock()

    init(containers: [Container]) { self.containers = containers }

    func systemStatus() async throws -> SystemStatus? { nil }
    func systemProperties() async throws -> String { "" }
    func listContainers(all: Bool) async throws -> [Container] {
        let count = lock.withLock { lists += 1; return lists }
        return listed?(count) ?? containers
    }
    func listImages() async throws -> [ContainerImage] { [] }
    func startContainer(_ id: String) async throws {}
    func stopContainer(_ id: String, timeout: Int32?, signal: String?) async throws {}
    func killContainer(_ id: String, signal: String?) async throws {}
    func deleteContainer(_ id: String, force: Bool) async throws {}
    func waitContainer(_ id: String) async throws -> ContainerExit { ContainerExit(code: 0, exitedAt: nil) }
    func createContainer(_ arguments: [String]) async throws {}
    func createVolume(_ name: String) async throws {}
    func deleteVolume(_ name: String) async throws {}
    func pullImage(_ reference: String, platform: String?) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func containerLogs(_ id: String, follow: Bool) -> AsyncThrowingStream<String, Error> {
        if let logStream { return logStream(follow) }
        let lines = self.lines
        return AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
    func containerStats(_ id: String) async throws -> ContainerStats {
        lock.withLock {
            defer { statsIndex = min(statsIndex + 1, stats.count - 1) }
            return stats[statsIndex]
        }
    }
    func bootstrapContainer(_ id: String, stdio: ProcessStdio) async throws {}
    func createProcess(_ container: String, process: String, spec: ProcessSpec, stdio: ProcessStdio) async throws {}
    func startProcess(_ container: String, process: String) async throws {}
    func resizeProcess(_ container: String, process: String, width: Int, height: Int) async throws {}
    func waitProcess(_ container: String, process: String) async throws -> ContainerExit { ContainerExit(code: 0, exitedAt: nil) }
    func execute(_ id: String, command: [String]) async throws -> Data { Data() }
    func copy(from source: String, to destination: String) async throws {}
    func exportContainer(_ id: String, to path: String) async throws {}
    func startServices() async throws {}
    func deleteImage(_ reference: String, force: Bool) async throws {}
    func pruneImages(all: Bool) async throws {}
    func inspectImage(_ reference: String) async throws -> ImageDetails { throw EngineError.notFound(reference) }
    func tagImage(_ source: String, as target: String) async throws {}
    func saveImages(_ references: [String], platform: String?, to path: String) async throws {}
    func loadImages(from path: String) async throws -> String { "" }
    func pushImage(_ reference: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func buildImage(_ options: BuildOptions) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
}

final class LogsStatsAPITests: XCTestCase {

    private func containers(tty: Bool = false) throws -> [Container] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/container-list-1.6.1", withExtension: "json"))
        var text = try String(contentsOf: url, encoding: .utf8)
        if tty { text = text.replacingOccurrences(of: #""terminal":false"#, with: #""terminal":true"#) }
        return try JSONDecoder().decode([Container].self, from: Data(text.utf8))
    }

    private func collect(_ response: HTTPResponse) async throws -> Data {
        guard case .stream(let stream) = response.body else {
            if case .data(let data) = response.body { return data }
            return Data()
        }
        var data = Data()
        for try await chunk in stream { data.append(chunk) }
        return data
    }

    /// Split multiplexed frames into (stream, text).
    private func frames(_ data: Data) -> [(UInt8, String)] {
        var result: [(UInt8, String)] = []
        var index = data.startIndex
        while index + 8 <= data.endIndex {
            let stream = data[index]
            let size = data[(index + 4)..<(index + 8)].reduce(0) { $0 << 8 | Int($1) }
            let payload = data[(index + 8)..<(index + 8 + size)]
            result.append((stream, String(decoding: payload, as: UTF8.self)))
            index += 8 + size
        }
        return result
    }

    private func router(_ engine: LogEngine) -> DockerRouter {
        var router = DockerRouter()
        LogsStatsAPI.register(on: &router, backend: engine)
        return router
    }

    func testLogsAreFramedAsStdoutAndHonourTail() async throws {
        let engine = LogEngine(containers: try containers())
        engine.lines = ["one", "two", "three"]
        let response = await router(engine).handle(HTTPRequest(method: "GET", target: "/containers/ib-fx-redis/logs?stdout=1&stderr=1&tail=2"))
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(response.headers.contains { $0 == ("Content-Type", "application/vnd.docker.multiplexed-stream") })
        let data = try await collect(response)
        let parsed = frames(data)
        XCTAssertEqual(parsed.map(\.0), [1, 1])
        XCTAssertEqual(parsed.map(\.1), ["two\n", "three\n"])
    }

    func testLogsWithoutTailEmitBeforeHistoryEnds() async throws {
        let engine = LogEngine(containers: try containers())
        let (history, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        engine.logStream = { _ in history }
        let response = await router(engine).handle(HTTPRequest(method: "GET", target: "/containers/ib-fx-redis/logs?stdout=1"))
        let received = expectation(description: "first history line")
        let task = Task {
            guard case .stream(let stream) = response.body else { XCTFail("not a stream"); return }
            for try await chunk in stream {
                XCTAssertEqual(chunk, LogsStatsAPI.frame(Data("early\n".utf8)))
                received.fulfill()
            }
        }
        continuation.yield("early")
        await fulfillment(of: [received], timeout: 1)
        continuation.finish()
        try await task.value
    }

    func testTailWrapsAndFollowSkipsAllHistory() async throws {
        for tail in [nil, 0, 2, 10] as [Int?] {
            let engine = LogEngine(containers: try containers())
            engine.logStream = { follow in
                AsyncThrowingStream { continuation in
                    for line in ["one", "two", "three", "four", "five"] { continuation.yield(line) }
                    if follow { continuation.yield("live") }
                    continuation.finish()
                }
            }
            let response = await router(engine).handle(HTTPRequest(method: "GET", target: "/containers/ib-fx-redis/logs?stdout=1&follow=1" + (tail.map { "&tail=\($0)" } ?? "")))
            let data = try await collect(response)
            let expected = Array(["one\n", "two\n", "three\n", "four\n", "five\n"].suffix(tail ?? 5)) + ["live\n"]
            XCTAssertEqual(frames(data).map(\.1), expected)
        }
    }

    func testLogTimeFiltersAndStderrOnly() async throws {
        let engine = LogEngine(containers: try containers())
        engine.lines = ["one", "two"]
        for query in ["stdout=1&since=4102444800", "stdout=1&until=1", "stderr=1"] {
            let response = await router(engine).handle(HTTPRequest(method: "GET", target: "/containers/ib-fx-redis/logs?\(query)"))
            let data = try await collect(response)
            XCTAssertTrue(data.isEmpty, query)
        }
        let response = await router(engine).handle(HTTPRequest(method: "GET", target: "/containers/ib-fx-redis/logs?stdout=1&since=1&until=4102444800"))
        let data = try await collect(response)
        XCTAssertEqual(frames(data).map(\.1), ["one\n", "two\n"])
    }

    func testFollowEndsWhenTheContainerStopsAndCancelsTheReader() async throws {
        let engine = LogEngine(containers: try containers())
        let running = engine.containers
        let stopped = try JSONDecoder().decode([Container].self, from: JSONEncoder().encode(running)
            .replacing(Data("running".utf8), with: Data("stopped".utf8)))
        engine.listed = { count in count == 1 ? running : stopped }
        let cancelled = expectation(description: "follow reader cancelled")
        engine.logStream = { follow in
            AsyncThrowingStream { continuation in
                continuation.yield("history")
                if follow {
                    continuation.yield("last")
                    continuation.onTermination = { _ in cancelled.fulfill() }
                } else {
                    continuation.finish()
                }
            }
        }
        let start = ContinuousClock.now
        let response = await router(engine).handle(HTTPRequest(method: "GET", target: "/containers/ib-fx-redis/logs?stdout=1&follow=1"))
        let data = try await collect(response)
        XCTAssertEqual(frames(data).map(\.1), ["history\n", "last\n"])
        // Checked every second, as Docker ends `logs -f` soon after the stop.
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        XCTAssertEqual(engine.listCount, 2)
        await fulfillment(of: [cancelled], timeout: 1)
    }

    func testCancellingHistoryStopsTheBackendReader() async throws {
        let engine = LogEngine(containers: try containers())
        let started = expectation(description: "history started")
        let cancelled = expectation(description: "history cancelled")
        engine.logStream = { _ in
            AsyncThrowingStream { continuation in
                continuation.onTermination = { _ in cancelled.fulfill() }
                started.fulfill()
            }
        }
        let response = await router(engine).handle(HTTPRequest(method: "GET", target: "/containers/ib-fx-redis/logs?stdout=1"))
        let task = Task {
            guard case .stream(let stream) = response.body else { return XCTFail("not a stream") }
            for try await _ in stream {}
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        _ = try await task.value
        await fulfillment(of: [cancelled], timeout: 1)
    }

    func testLogTimestampExactFormat() {
        XCTAssertEqual(LogsStatsAPI.timestamp(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00.000000000Z")
        XCTAssertEqual(LogsStatsAPI.timestamp(Date(timeIntervalSince1970: 1_800_000_000.125)), "2027-01-15T08:00:00.125000000Z")
        XCTAssertEqual(LogsStatsAPI.timestamp(Date(timeIntervalSince1970: -0.5)), "1969-12-31T23:59:59.500000000Z")
    }

    func testNegativeTailMeansAll() async throws {
        let engine = LogEngine(containers: try containers())
        engine.lines = ["one", "two"]
        let response = await router(engine).handle(HTTPRequest(method: "GET", target: "/containers/ib-fx-redis/logs?stdout=1&tail=-1"))
        XCTAssertEqual(response.status, 200)
        let data = try await collect(response)
        XCTAssertEqual(frames(data).map(\.1), ["one\n", "two\n"])
    }

    func testTTYLogsAreRawAndTimestampsPrefixLines() async throws {
        let engine = LogEngine(containers: try containers(tty: true))
        engine.lines = ["hello"]
        let response = await router(engine).handle(HTTPRequest(method: "GET", target: "/containers/ib-fx-redis/logs?stdout=true&timestamps=1"))
        let data = try await collect(response)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertNotNil(text.wholeMatch(of: /\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{9}Z hello\n/), text)
    }

    func testLogsNeedAStream() async throws {
        let engine = LogEngine(containers: try containers())
        let response = await router(engine).handle(HTTPRequest(method: "GET", target: "/containers/ib-fx-redis/logs"))
        XCTAssertEqual(response.status, 400)
    }

    func testStatsLetDockerComputePercentOfOneCore() async throws {
        let engine = LogEngine(containers: try containers())
        func stats(_ cpuUsec: Int64) -> ContainerStats {
            ContainerStats(id: "ib-fx-redis", cpuUsageUsec: cpuUsec, memoryUsageBytes: 50 << 20, memoryLimitBytes: 1 << 30,
                           networkRxBytes: 10, networkTxBytes: 20, blockReadBytes: 30, blockWriteBytes: 40, numProcesses: 4)
        }
        // 1.5 s of CPU time over the ~1 s between the two samples ≈ 150%.
        engine.stats = [stats(1_000_000), stats(2_500_000)]
        let response = await router(engine).handle(HTTPRequest(method: "GET", target: "/containers/ib-fx-redis/stats?stream=false"))
        let body = try await collect(response)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let cpu = try XCTUnwrap(json["cpu_stats"] as? [String: Any])
        let pre = try XCTUnwrap(json["precpu_stats"] as? [String: Any])
        func usage(_ s: [String: Any]) -> Double { Double((s["cpu_usage"] as! [String: Any])["total_usage"] as! Int) }
        let cpuDelta = usage(cpu) - usage(pre)
        let systemDelta = Double(cpu["system_cpu_usage"] as! Int) - Double(pre["system_cpu_usage"] as! Int)
        let online = Double(cpu["online_cpus"] as! Int)
        let percent = cpuDelta / systemDelta * online * 100     // docker stats' formula
        XCTAssertEqual(percent, 150, accuracy: 10)
        let memory = try XCTUnwrap(json["memory_stats"] as? [String: Any])
        XCTAssertEqual(memory["usage"] as? Int, 50 << 20)
        XCTAssertEqual((json["pids_stats"] as? [String: Any])?["current"] as? Int, 4)
        XCTAssertEqual(json["name"] as? String, "/ib-fx-redis")
    }
}
