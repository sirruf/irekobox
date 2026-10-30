import XCTest
import ContainerKit
@testable import DockerAPIKit

final class HealthMonitorTests: XCTestCase {
    private let started = Date(timeIntervalSince1970: 1000)

    private func probe(_ code: Int, at seconds: TimeInterval) -> HealthMonitor.Probe {
        HealthMonitor.Probe(start: started.addingTimeInterval(seconds), end: started.addingTimeInterval(seconds),
                            exitCode: code, output: code == 0 ? "ok" : "fail")
    }

    func testDockersStateMachine() {
        let config = HealthMonitor.Config(Test: ["CMD", "true"], Retries: 2, StartPeriod: 10_000_000_000)
        var health = HealthMonitor.Health()
        HealthMonitor.apply(probe(1, at: 2), to: &health, config: config, started: started)
        XCTAssertEqual(health.status, .starting, "failures in the start period don't count")
        XCTAssertEqual(health.failingStreak, 0)
        HealthMonitor.apply(probe(0, at: 4), to: &health, config: config, started: started)
        XCTAssertEqual(health.status, .healthy)
        HealthMonitor.apply(probe(1, at: 6), to: &health, config: config, started: started)
        XCTAssertEqual(health.status, .healthy, "after a pass, start-period failures count, but one isn't enough")
        XCTAssertEqual(health.failingStreak, 1)
        HealthMonitor.apply(probe(1, at: 8), to: &health, config: config, started: started)
        XCTAssertEqual(health.status, .unhealthy)
        HealthMonitor.apply(probe(0, at: 12), to: &health, config: config, started: started)
        XCTAssertEqual(health.status, .healthy)
        XCTAssertEqual(health.failingStreak, 0)
        for second in 13...20 { HealthMonitor.apply(probe(0, at: TimeInterval(second)), to: &health, config: config, started: started) }
        XCTAssertEqual(health.log.count, 5, "the last five probes are kept")
    }

    func testConfigFormsAndDefaults() {
        XCTAssertEqual(HealthMonitor.Config(Test: ["CMD-SHELL", "curl -f localhost"]).command, ["/bin/sh", "-c", "curl -f localhost"])
        XCTAssertEqual(HealthMonitor.Config(Test: ["CMD", "pg_isready", "-U", "x"]).command, ["pg_isready", "-U", "x"])
        XCTAssertNil(HealthMonitor.Config(Test: ["NONE"]).command)
        XCTAssertNil(HealthMonitor.Config(Test: nil).command)
        let defaults = HealthMonitor.Config(Test: ["CMD", "true"])
        XCTAssertEqual(defaults.interval, 30)
        XCTAssertEqual(defaults.timeout, 30)
        XCTAssertEqual(defaults.retries, 3)
        XCTAssertEqual(HealthMonitor.Config(Test: ["CMD", "true"], Interval: 2_500_000_000).interval, 2.5)
    }

    func testTimeoutFailsTheProbe() async {
        final class Slow: DockerBackend, @unchecked Sendable {
            func execute(_ id: String, command: [String]) async throws -> Data {
                try await Task.sleep(for: .seconds(5))
                return Data()
            }
            func systemStatus() async throws -> SystemStatus? { nil }
            func systemProperties() async throws -> String { "" }
            func listContainers(all: Bool) async throws -> [Container] { [] }
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
            func containerLogs(_ id: String, follow: Bool) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
            func containerStats(_ id: String) async throws -> ContainerStats { throw EngineError.notFound(id) }
            func bootstrapContainer(_ id: String, stdio: ProcessStdio) async throws {}
            func createProcess(_ container: String, process: String, spec: ProcessSpec, stdio: ProcessStdio) async throws {}
            func startProcess(_ container: String, process: String) async throws {}
            func resizeProcess(_ container: String, process: String, width: Int, height: Int) async throws {}
            func waitProcess(_ container: String, process: String) async throws -> ContainerExit { ContainerExit(code: 0, exitedAt: nil) }
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
        let clock = ContinuousClock.now
        let (code, output) = await HealthMonitor.execRunner(Slow())("web", ["sleep", "9"], 0.3)
        XCTAssertEqual(code, -1)
        XCTAssertTrue(output.contains("timeout"))
        XCTAssertLessThan(ContinuousClock.now - clock, .seconds(2))
    }

    func testStatusTextShowsHealth() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/container-list-1.6.1", withExtension: "json"))
        let redis = try XCTUnwrap(try JSONDecoder().decode([Container].self, from: Data(contentsOf: fixture)).first { $0.id == "ib-fx-redis" })
        var item = DockerContainer(container: redis, id: "x", state: .running, exit: nil)
        item.health = HealthMonitor.Health(status: .unhealthy, failingStreak: 3, log: [])
        XCTAssertTrue(item.statusText().hasSuffix("(unhealthy)"))
        item.health?.status = .starting
        XCTAssertTrue(item.statusText().hasSuffix("(health: starting)"))
    }

    func testHealthEventsMatchDockersPrefixFilter() throws {
        let event = DockerEvent(type: "container", action: "health_status: unhealthy", actorID: "x", attributes: ["name": "web"], time: Date())
        XCTAssertTrue(EventsAPI.matches(event, try DockerFilters(query: #"{"event":["health_status"]}"#)))
        XCTAssertFalse(EventsAPI.matches(event, try DockerFilters(query: #"{"event":["health"]}"#)))
    }
}
