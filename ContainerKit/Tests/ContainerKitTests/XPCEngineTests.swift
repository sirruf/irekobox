import XCTest
@testable import ContainerKit

/// apiserver XPC payloads (captured from `container` 1.6.1, `Fixtures/1.6.1/xpc`)
/// must decode into the same models as the CLI output.
final class XPCPayloadTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json",
                                                  subdirectory: "Fixtures/1.6.1/xpc"))
        return try Data(contentsOf: url)
    }

    func testContainerSnapshots() throws {
        let data = try XPCPayload.containers(fixture("container-list"))
        let containers = try JSONDecoder().decode([Container].self, from: data)
        XCTAssertEqual(Set(containers.map(\.id)), ["ib-fx-redis", "ib-fx-stopped", "buildkit"])

        let redis = try XCTUnwrap(containers.first { $0.id == "ib-fx-redis" })
        XCTAssertEqual(redis.state, .running)
        XCTAssertEqual(redis.ipv4Address, "192.168.65.2")
        XCTAssertNotNil(redis.startedDate)
        XCTAssertEqual(redis.configuration.publishedPorts?.first?.hostPort, 16379)
        XCTAssertEqual(redis.configuration.mounts?.first?.volumeName, "ib-fx-vol")
        XCTAssertEqual(redis.configuration.labels["app"], "fixture")
        // Reference-date seconds became ISO-8601 the CLI way.
        XCTAssertTrue(redis.configuration.creationDate.hasPrefix("2026-10-26T"),
                      redis.configuration.creationDate)

        let stopped = try XCTUnwrap(containers.first { $0.id == "ib-fx-stopped" })
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertNil(stopped.startedDate)
        XCTAssertTrue(try XCTUnwrap(containers.first { $0.id == "buildkit" }).isSystem)
    }

    func testStats() throws {
        let stats = try JSONDecoder().decode(ContainerStats.self, from: fixture("container-stats"))
        XCTAssertEqual(stats.id, "ib-fx-redis")
        XCTAssertEqual(stats.numProcesses, 6)
    }

    func testVolumes() throws {
        let volumes = try JSONDecoder().decode([Volume].self, from: XPCPayload.volumes(fixture("volume-list")))
        let volume = try XCTUnwrap(volumes.first { $0.name == "ib-fx-vol" })
        XCTAssertEqual(volume.id, "ib-fx-vol")
        XCTAssertEqual(volume.driver, "local")
    }

    func testNetworks() throws {
        let networks = try JSONDecoder().decode([Network].self,
                                                from: XPCPayload.normalizingDates(fixture("network-list")))
        let network = try XCTUnwrap(networks.first { $0.name == "ib-fx-net" })
        XCTAssertFalse(network.isBuiltin)
        XCTAssertNotNil(network.subnet)
        XCTAssertTrue(try XCTUnwrap(network.configuration.creationDate).hasPrefix("2026-"))
    }

    func testDiskUsage() throws {
        let df = try JSONDecoder().decode(SystemDiskUsage.self,
                                          from: XPCPayload.normalizingDates(fixture("system-df")))
        XCTAssertEqual(df.containers.total, 3)
        XCTAssertEqual(df.volumes.active, 1)
    }

    func testServerErrorMapping() {
        XCTAssertEqual(EngineError.fromServer(code: "notFound", message: "gone"), .notFound("gone"))
        XCTAssertEqual(EngineError.fromServer(code: "exists", message: "dup"), .conflict("dup"))
        XCTAssertEqual(EngineError.fromServer(code: "timeout", message: ""), .timedOut)
        XCTAssertEqual(EngineError.fromServer(code: "invalidState", message: "busy"),
                       .serviceError(code: "invalidState", message: "busy"))
    }

    func testUnreachableServiceMeansServicesNotRunning() async throws {
        let connection = APIServerConnection(serviceName: "com.irekobox.tests.no-such-service")
        do {
            _ = try await connection.send(.init(route: "containerList"), timeout: .seconds(5))
            XCTFail("expected failure")
        } catch let error as EngineError {
            XCTAssertEqual(error, .servicesNotRunning)
        }
    }
}

final class LogFileStreamTests: XCTestCase {

    private func tempLog(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ib-log-\(UUID().uuidString)")
        try content.write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func testReadsExistingContentWithoutFollow() async throws {
        let url = try tempLog("one\ntwo\nthree")
        var lines: [String] = []
        for try await line in LogFileStream.lines(of: try FileHandle(forReadingFrom: url), follow: false) {
            lines.append(line)
        }
        XCTAssertEqual(lines, ["one", "two", "three"])
    }

    func testLongLogStartsAtAWholeLineOfItsTail() async throws {
        let line = String(repeating: "x", count: 99) + "\n"
        let count = Int(LogFileStream.tailLimit) / line.utf8.count + 1000
        let url = try tempLog(String(repeating: line, count: count) + "last\n")
        var lines: [String] = []
        for try await line in LogFileStream.lines(of: try FileHandle(forReadingFrom: url), follow: false) {
            lines.append(line)
        }
        XCTAssertEqual(lines.last, "last")
        XCTAssertLessThan(lines.count, count)
        XCTAssertTrue(lines.dropLast().allSatisfy { $0.count == 99 }, "no partial first line")
    }

    func testOverlongLineComesOutInPieces() {
        let splitter = LineSplitter()
        let pieces = splitter.append(Data(String(repeating: "y", count: LineSplitter.maxLine * 2 + 5).utf8))
        XCTAssertEqual(pieces.map(\.count), [LineSplitter.maxLine, LineSplitter.maxLine])
        XCTAssertEqual(splitter.flush()?.count, 5)
    }

    func testFollowsAppendsAndTruncation() async throws {
        let url = try tempLog("old\n")
        let stream = LogFileStream.lines(of: try FileHandle(forReadingFrom: url), follow: true)
        var iterator = stream.makeAsyncIterator()

        let first = try await iterator.next()
        XCTAssertEqual(first, "old")

        try append("new\n", to: url)
        let appended = try await iterator.next()
        XCTAssertEqual(appended, "new")

        // A restart truncates the log; reading resumes from the start.
        try "fresh\n".write(to: url, atomically: false, encoding: .utf8)
        let truncated = try await iterator.next()
        XCTAssertEqual(truncated, "fresh")
    }
}

/// Contract tests against a live apiserver: the XPC engine must agree with the
/// CLI engine. Opt in with `IREKOBOX_LIVE_TESTS=1` (services running).
final class XPCEngineLiveTests: XCTestCase {
    private var cli: CLIEngine!
    private var xpc: XPCEngine!

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["IREKOBOX_LIVE_TESTS"] == "1" else {
            throw XCTSkip("set IREKOBOX_LIVE_TESTS=1 to run against a live apiserver")
        }
        cli = CLIEngine()
        xpc = XPCEngine(fallback: cli)
    }

    func testContainerListsAgree() async throws {
        let viaCLI = try await cli.listContainers(all: true)
        let viaXPC = try await xpc.listContainers(all: true)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: viaCLI.map { ($0.id, $0.state) }),
                       Dictionary(uniqueKeysWithValues: viaXPC.map { ($0.id, $0.state) }))
        for container in viaCLI {
            let other = try XCTUnwrap(viaXPC.first { $0.id == container.id })
            XCTAssertEqual(container.configuration.publishedPorts, other.configuration.publishedPorts)
            XCTAssertEqual(container.configuration.image.reference, other.configuration.image.reference)
            XCTAssertEqual(container.ipv4Address, other.ipv4Address)
            XCTAssertEqual(container.configuration.creationDate, other.configuration.creationDate)
        }
        let running = try await xpc.listContainers(all: false)
        XCTAssertTrue(running.allSatisfy { $0.state.isRunning })
    }

    func testResourcesAgree() async throws {
        let cliVolumes = try await cli.listVolumes().map(\.name).sorted()
        let xpcVolumes = try await xpc.listVolumes().map(\.name).sorted()
        XCTAssertEqual(cliVolumes, xpcVolumes)

        let cliNetworks = try await cli.listNetworks().map(\.name).sorted()
        let xpcNetworks = try await xpc.listNetworks().map(\.name).sorted()
        XCTAssertEqual(cliNetworks, xpcNetworks)

        let cliDF = try await cli.diskUsage()
        let xpcDF = try await xpc.diskUsage()
        XCTAssertEqual(cliDF.containers.total, xpcDF.containers.total)
        XCTAssertEqual(cliDF.images.total, xpcDF.images.total)
    }

    func testStatsAndLogsOfARunningContainer() async throws {
        guard let running = try await xpc.listContainers(all: false).first(where: { !$0.isSystem }) else {
            throw XCTSkip("no running container")
        }
        let stats = try await xpc.containerStats(running.id)
        XCTAssertEqual(stats.id, running.id)

        var cliLines: [String] = []
        for try await line in cli.containerLogs(running.id, follow: false) { cliLines.append(line) }
        var xpcLines: [String] = []
        for try await line in xpc.containerLogs(running.id, follow: false) { xpcLines.append(line) }
        XCTAssertEqual(cliLines.filter { !$0.isEmpty }, xpcLines.filter { !$0.isEmpty })
    }

    func testLifecycleThroughXPC() async throws {
        let id = "ib-xpc-lifecycle"
        try? await cli.deleteContainer(id, force: true)
        try await cli.cli.run(["run", "--detach", "--name", id, "alpine:latest", "sleep", "300"])
        defer { Task { [cli] in try? await cli!.deleteContainer(id, force: true) } }

        var state = try await xpc.inspectContainer(id).state
        XCTAssertEqual(state, .running)

        try await xpc.stopContainer(id)
        state = try await xpc.inspectContainer(id).state
        XCTAssertEqual(state, .stopped)

        try await xpc.startContainer(id)   // CLI fallback
        state = try await xpc.inspectContainer(id).state
        XCTAssertEqual(state, .running)

        try await xpc.killContainer(id, signal: nil)
        try await Task.sleep(for: .seconds(1))
        state = try await xpc.inspectContainer(id).state
        XCTAssertNotEqual(state, .running)

        try await xpc.deleteContainer(id, force: true)
        do {
            _ = try await xpc.inspectContainer(id)
            XCTFail("expected the container to be gone")
        } catch EngineError.notFound {}
    }

    func testFollowingLogsYieldsNewLines() async throws {
        let id = "ib-xpc-ticker"
        try? await cli.deleteContainer(id, force: true)
        try await cli.cli.run(["run", "--detach", "--name", id, "alpine:latest",
                               "sh", "-c", "i=0; while true; do i=$((i+1)); echo tick-$i; sleep 0.3; done"])
        defer { Task { [cli] in try? await cli!.deleteContainer(id, force: true) } }

        var ticks: [String] = []
        for try await line in xpc.containerLogs(id, follow: true) where line.hasPrefix("tick-") {
            ticks.append(line)
            if ticks.count == 5 { break }
        }
        XCTAssertEqual(ticks.count, 5)
        let numbers = ticks.compactMap { Int($0.dropFirst("tick-".count)) }
        XCTAssertEqual(numbers, numbers.sorted())
        XCTAssertEqual(Set(numbers).count, 5)
    }

    func testVolumeDiskUsageAgrees() async throws {
        guard let volume = try await cli.listVolumes().first else { throw XCTSkip("no volume") }
        let viaCLI = try await cli.volumeDiskUsage(volume.name)
        let viaXPC = try await xpc.volumeDiskUsage(volume.name)
        XCTAssertGreaterThan(viaXPC, 0)
        XCTAssertLessThan(viaXPC, volume.configuration.sizeInBytes ?? .max, "usage, not the sparse capacity")
        XCTAssertEqual(Double(viaCLI), Double(viaXPC), accuracy: Double(viaXPC) * 0.05 + 1_048_576)
    }

    func testMissingContainerIsNotFound() async throws {
        do {
            try await xpc.deleteContainer("ib-no-such-container", force: false)
            XCTFail("expected failure")
        } catch let error as EngineError {
            guard case .notFound = error else { return XCTFail("got \(error)") }
        }
    }
}
