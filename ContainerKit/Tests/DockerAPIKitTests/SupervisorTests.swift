import XCTest
import ContainerKit
@testable import DockerAPIKit

/// Containers keyed by name; starts flip them to running.
private final class SupervisedEngine: DockerBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var containers: [String: Container] = [:]
    private(set) var started: [String] = []
    var engineRunning = true

    func add(_ name: String, policy: String?, running: Bool, startedAt: String? = "2026-10-26T00:00:00Z") throws {
        let labels = policy.map { #"{"com.irekobox.docker.restart":"\#($0)"}"# } ?? "{}"
        let started = startedAt.map { #","startedDate":"\#($0)""# } ?? ""
        let json = #"""
        {"id":"\#(name)","status":{"state":"\#(running ? "running" : "stopped")","networks":[]\#(started)},
         "configuration":{"id":"\#(name)","image":{"reference":"alpine","descriptor":{"digest":"d","mediaType":"m","size":1}},
           "resources":{"cpus":1,"memoryInBytes":1},"platform":{"architecture":"arm64","os":"linux"},"networks":[],
           "initProcess":{"executable":"sh","arguments":[],"workingDirectory":"/","environment":[]},
           "labels":\#(labels),"creationDate":"2026-10-26T00:00:00Z","readOnly":false,"runtimeHandler":"x","rosetta":false}}
        """#
        let container = try JSONDecoder().decode(Container.self, from: Data(json.utf8))
        lock.withLock { containers[name] = container }
    }

    func setRunning(_ name: String, _ running: Bool) throws {
        let policy = lock.withLock { containers[name]?.configuration.labels["com.irekobox.docker.restart"] }
        try add(name, policy: policy, running: running)
    }

    func systemStatus() async throws -> SystemStatus? {
        try JSONDecoder().decode(SystemStatus.self, from: Data(#"{"status":"\#(engineRunning ? "running" : "unregistered")"}"#.utf8))
    }
    // Over XPC the list answers only while the services run.
    func listContainers(all: Bool) async throws -> [Container] {
        guard engineRunning else { throw EngineError.servicesNotRunning }
        return lock.withLock { Array(containers.values) }
    }
    func startContainer(_ id: String) async throws {
        lock.withLock { started.append(id) }
        try setRunning(id, true)
    }
    func systemProperties() async throws -> String { "" }
    func listImages() async throws -> [ContainerImage] { [] }
    func stopContainer(_ id: String, timeout: Int32?, signal: String?) async throws {}
    func killContainer(_ id: String, signal: String?) async throws {}
    func deleteContainer(_ id: String, force: Bool) async throws {}
    /// Running: blocks like the real wait. Stopped: answers at once, like an
    /// apiserver that no longer holds the run.
    func waitContainer(_ id: String) async throws -> ContainerExit {
        let running = lock.withLock { containers[id]?.state.isRunning == true }
        guard running else { throw EngineError.serviceError(code: "invalidState", message: "container is stopped") }
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }
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

private final class Delays: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Duration] = []
    func add(_ value: Duration) { lock.withLock { values.append(value) } }
    var all: [Duration] { lock.withLock { values } }
}

final class SupervisorTests: XCTestCase {

    private func supervisor(_ engine: SupervisedEngine, file: URL? = nil) async -> (Supervisor, Delays) {
        let supervisor = Supervisor(backend: engine, exits: ExitRecorder(backend: engine), stateFile: file)
        let delays = Delays()
        await supervisor.useSleep { delays.add($0) }
        return (supervisor, delays)
    }

    private func exit(_ code: Int32, ranFor seconds: TimeInterval = 1) -> ContainerExit {
        ContainerExit(code: code, exitedAt: ISO8601DateFormatter().date(from: "2026-10-26T00:00:00Z")!.addingTimeInterval(seconds))
    }

    func testPolicyLabels() {
        XCTAssertEqual(Supervisor.Policy(label: "always"), .always)
        XCTAssertEqual(Supervisor.Policy(label: "unless-stopped"), .unlessStopped)
        XCTAssertEqual(Supervisor.Policy(label: "on-failure"), .onFailure(max: nil))
        XCTAssertEqual(Supervisor.Policy(label: "on-failure:3"), .onFailure(max: 3))
        XCTAssertNil(Supervisor.Policy(label: "no"))
        XCTAssertNil(Supervisor.Policy(label: nil))
        XCTAssertNil(Supervisor.Policy(label: "sometimes"))
    }

    func testAlwaysRestartsWithGrowingDelayThatResetsAfterAStableRun() async throws {
        let engine = SupervisedEngine()
        try engine.add("web", policy: "always", running: false)
        let (supervisor, delays) = await supervisor(engine)
        for _ in 0..<3 {
            await supervisor.handleExit("web", exit(0))
            await supervisor.settle()
            try engine.setRunning("web", false)
        }
        XCTAssertEqual(engine.started, ["web", "web", "web"])
        XCTAssertEqual(delays.all, [.milliseconds(100), .milliseconds(200), .milliseconds(400)])
        let count = await supervisor.restartCount("web")
        XCTAssertEqual(count, 3)

        await supervisor.handleExit("web", exit(1, ranFor: 30))   // ran 30 s: back to the first delay
        await supervisor.settle()
        XCTAssertEqual(delays.all.last, .milliseconds(100))
    }

    func testOnFailureRespectsCodeAndLimit() async throws {
        let engine = SupervisedEngine()
        try engine.add("job", policy: "on-failure:2", running: false)
        let (supervisor, _) = await supervisor(engine)
        await supervisor.handleExit("job", exit(0))
        await supervisor.settle()
        XCTAssertTrue(engine.started.isEmpty, "a clean exit is not a failure")
        for _ in 0..<3 {
            await supervisor.handleExit("job", exit(1))
            await supervisor.settle()
            try engine.setRunning("job", false)
        }
        XCTAssertEqual(engine.started.count, 2, "at most 2 restarts")
    }

    func testAStopByHandIsNotRestartedUntilAStartByHand() async throws {
        let engine = SupervisedEngine()
        try engine.add("web", policy: "always", running: false)
        let (supervisor, _) = await supervisor(engine)
        await supervisor.stoppedByHand("web")
        await supervisor.handleExit("web", exit(143))
        await supervisor.settle()
        XCTAssertTrue(engine.started.isEmpty)

        await supervisor.startedByHand("web")
        await supervisor.handleExit("web", exit(137))
        await supervisor.settle()
        XCTAssertEqual(engine.started, ["web"])
    }

    func testNothingRestartsWhileTheEngineIsDown() async throws {
        let engine = SupervisedEngine()
        try engine.add("web", policy: "always", running: false)
        engine.engineRunning = false
        let (supervisor, _) = await supervisor(engine)
        await supervisor.handleExit("web", exit(137))
        await supervisor.settle()
        XCTAssertTrue(engine.started.isEmpty)
    }

    func testEngineStartBringsBackAlwaysAndUnlessStoppedLikeDocker() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "ib-sup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = SupervisedEngine()
        try engine.add("a-always", policy: "always", running: false)
        try engine.add("b-always-by-hand", policy: "always", running: false)
        try engine.add("c-unless", policy: "unless-stopped", running: false)
        try engine.add("d-unless-by-hand", policy: "unless-stopped", running: false)
        try engine.add("e-on-failure", policy: "on-failure", running: false)
        try engine.add("f-none", policy: nil, running: false)
        engine.engineRunning = false
        let (supervisor, _) = await supervisor(engine, file: file)
        await supervisor.stoppedByHand("b-always-by-hand")
        await supervisor.stoppedByHand("d-unless-by-hand")
        await supervisor.watchEngine()          // engine down: nothing
        XCTAssertTrue(engine.started.isEmpty)

        engine.engineRunning = true
        await supervisor.watchEngine()          // engine started
        XCTAssertEqual(engine.started.sorted(), ["a-always", "b-always-by-hand", "c-unless"])

        // An agent restart while the engine keeps running is not an engine start.
        try engine.setRunning("a-always", false)
        let (restarted, _) = await self.supervisor(engine, file: file)
        await restarted.watchEngine()
        XCTAssertEqual(engine.started.count, 3)
    }

    func testForgetClearsAContainerThatWasRemoved() async throws {
        let engine = SupervisedEngine()
        try engine.add("web", policy: "always", running: false)
        let (supervisor, _) = await supervisor(engine)
        await supervisor.stoppedByHand("web")
        await supervisor.forget("web")
        await supervisor.handleExit("web", exit(1))
        await supervisor.settle()
        XCTAssertEqual(engine.started, ["web"], "a new container with the name starts clean")
    }

    func testAStopDuringTheRestartDelayCancelsIt() async throws {
        let engine = SupervisedEngine()
        try engine.add("web", policy: "always", running: false)
        let supervisor = Supervisor(backend: engine, exits: ExitRecorder(backend: engine), stateFile: nil)
        // A real (long) delay, so the stop lands while the restart is pending.
        await supervisor.useSleep { _ in try? await Task.sleep(for: .milliseconds(300)) }
        await supervisor.handleExit("web", exit(1))
        await supervisor.stoppedByHand("web")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(engine.started.isEmpty)
    }

    func testDockerStopOfAContainerBetweenRestartsIsStillAStopByHand() async throws {
        let engine = SupervisedEngine()
        try engine.add("web", policy: "always", running: false)   // crashed, restart pending
        let supervisor = Supervisor(backend: engine, exits: ExitRecorder(backend: engine), stateFile: nil)
        var router = DockerRouter()
        ContainersAPI.register(on: &router, backend: engine, supervisor: supervisor)
        let response = await router.handle(HTTPRequest(method: "POST", target: "/containers/web/stop"))
        XCTAssertEqual(response.status, 304)
        let stopped = await supervisor.isStoppedByHand("web")
        XCTAssertTrue(stopped)
    }

    func testServiceCrashesAreAlertedButHandStopsAndOneOffsAreNot() async throws {
        let engine = SupervisedEngine()
        try engine.add("svc", policy: "on-failure:1", running: false)
        try engine.add("oneoff", policy: nil, running: false)
        try engine.add("byhand", policy: "always", running: false)
        let supervisor = Supervisor(backend: engine, exits: ExitRecorder(backend: engine), stateFile: nil)
        let alerts = AlertLog(now: Date(timeIntervalSince1970: 0))
        supervisor.alerts = alerts
        await supervisor.useSleep { _ in }
        await supervisor.stoppedByHand("byhand")
        await supervisor.handleExit("byhand", exit(137))
        await supervisor.handleExit("oneoff", exit(3))
        await supervisor.handleExit("svc", exit(2))      // restarts once
        await supervisor.settle()
        try engine.setRunning("svc", false)
        await supervisor.handleExit("svc", exit(2))      // limit reached
        let log = await alerts.after(0)
        XCTAssertEqual(log.map(\.kind), [.died, .died, .gaveUp])
        XCTAssertEqual(log.map(\.container), ["svc", "svc", "svc"])
        XCTAssertEqual(log.first?.detail, "Exited with code 2; restarting")
        let latest = await alerts.latest
        let none = await alerts.after(latest)
        XCTAssertTrue(none.isEmpty)
    }
}
