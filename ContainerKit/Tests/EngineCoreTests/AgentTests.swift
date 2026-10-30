import XCTest
import ContainerKit
@testable import EngineCore

/// Agent server and client over real NSXPC, in-process via an anonymous listener.
final class AgentTests: XCTestCase {
    private var engine: MockEngine!
    private var server: AgentServer!

    override func setUp() {
        engine = MockEngine()
        engine.containers = .success([container("web", "running")])
        let engine = self.engine!
        server = AgentServer(listener: .anonymous(), engine: engine,
                             intervals: .init(system: .milliseconds(50), containers: .milliseconds(50),
                                              others: .milliseconds(50)),
                             makeEngine: { _ in engine })
        server.resume()
    }

    private let configuration = AgentConfiguration(binaryPath: "/usr/local/bin/container",
                                                   containersIntervalMilliseconds: 50)

    private func connectedClient() async throws -> AgentClient {
        let client = AgentClient(endpoint: server.endpoint)
        try await client.connect(configuration: configuration)
        return client
    }

    private func eventually(_ timeout: Duration = .seconds(3), _ condition: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("condition not met in time")
    }

    func testUpdatesRoundTripThroughJSON() throws {
        var snapshot = EngineSnapshot()
        snapshot.service = .failed(.timedOut)
        snapshot.containers = Loadable(value: [container("a", "running")], error: .notFound("x"), updatedAt: Date())
        let update = EngineUpdate(snapshot: snapshot,
                                  events: [.containerStateChanged(id: "a", from: .stopped, to: .running)])
        let decoded = try JSONDecoder().decode(EngineUpdate.self, from: JSONEncoder().encode(update))
        XCTAssertEqual(decoded.events, update.events)
        XCTAssertEqual(decoded.snapshot.service, .failed(.timedOut))
        XCTAssertEqual(decoded.snapshot.containers.value?.map(\.id), ["a"])
        XCTAssertEqual(decoded.snapshot.containers.error, .notFound("x"))
    }

    func testHelloReportsProtocol() async throws {
        let client = AgentClient(endpoint: server.endpoint)
        let info = try await client.connect(configuration: configuration)
        XCTAssertEqual(info.protocolVersion, AgentConstants.protocolVersion)
        XCTAssertEqual(info.pid, ProcessInfo.processInfo.processIdentifier)
    }

    func testInterestDrivesPushedUpdates() async throws {
        let client = try await connectedClient()
        var updates = await client.updates().makeAsyncIterator()
        _ = await updates.next()

        _ = await client.addInterest([.containers])
        var ids: [String]?
        while ids == nil, let update = await updates.next() {
            ids = update.snapshot.containers.value?.map(\.id)
        }
        XCTAssertEqual(ids, ["web"])
    }

    func testRefreshReturnsFreshSnapshot() async throws {
        let client = try await connectedClient()
        engine.containers = .success([container("fresh", "stopped")])
        let snapshot = await client.refreshSnapshot([.system, .containers])
        XCTAssertEqual(snapshot.containers.value?.map(\.id), ["fresh"])
        XCTAssertTrue(snapshot.service.isRunning)
    }

    func testDisconnectDropsInterestAndVisibility() async throws {
        let client = try await connectedClient()
        _ = await client.addInterest([.images])
        await client.setVisible(true)
        let store = server.store
        try await eventually { await store.polledResources.contains(.images) }
        try await eventually { await !store.isBackground }

        client.disconnect()
        try await eventually { await !store.polledResources.contains(.images) }
        try await eventually { await store.isBackground }
    }

    func testInterestsSurviveForTwoClients() async throws {
        let first = try await connectedClient()
        let second = try await connectedClient()
        let token = await first.addInterest([.volumes])
        _ = await second.addInterest([.volumes])
        let store = server.store
        try await eventually { await store.polledResources.contains(.volumes) }

        await first.removeInterest(token)
        try await Task.sleep(for: .milliseconds(100))
        let stillPolled = await store.polledResources.contains(.volumes)
        XCTAssertTrue(stillPolled, "the second client still wants volumes")
    }

    func testRestartRequestReachesServer() async throws {
        let restarted = expectation(description: "restart")
        server.onRestart = { restarted.fulfill() }
        let client = try await connectedClient()
        client.restartAgent()
        await fulfillment(of: [restarted], timeout: 3)
    }

    // MARK: - Saved configuration and Docker status

    func testOldConfigurationJSONStillDecodes() throws {
        let old = Data(#"{"binaryPath":"/usr/local/bin/container","containersIntervalMilliseconds":2000}"#.utf8)
        let decoded = try JSONDecoder().decode(AgentConfiguration.self, from: old)
        XCTAssertFalse(decoded.dockerSocketEnabled)
    }

    func testTheLastConfigurationIsAppliedAtLaunchBeforeAnyClient() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "ib-agent-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = self.engine!
        let first = AgentServer(listener: .anonymous(), engine: engine, configurationFile: file, makeEngine: { _ in engine })
        first.resume()
        let client = AgentClient(endpoint: first.endpoint)
        try await client.connect(configuration: AgentConfiguration(binaryPath: "/usr/local/bin/container",
                                                                   containersIntervalMilliseconds: 50,
                                                                   dockerSocketEnabled: true))
        client.disconnect()

        // Next login: a new agent applies it on its own.
        final class Seen: @unchecked Sendable { var configuration: AgentConfiguration? }
        let seen = Seen()
        let second = AgentServer(listener: .anonymous(), engine: engine, configurationFile: file, makeEngine: { _ in engine })
        second.onConfigure = { seen.configuration = $0 }
        second.resume()
        try await eventually { seen.configuration != nil }
        XCTAssertEqual(seen.configuration?.dockerSocketEnabled, true)
    }

    func testDockerStatusCrossesXPC() async throws {
        server.dockerStatus = {
            DockerSocketStatus(enabled: true, listening: false, socketPath: "/tmp/x.sock", error: "in use")
        }
        let client = try await connectedClient()
        defer { client.disconnect() }
        let status = try await client.dockerStatus()
        XCTAssertEqual(status, DockerSocketStatus(enabled: true, listening: false, socketPath: "/tmp/x.sock", error: "in use"))
    }
}
