import XCTest
import ContainerKit
@testable import EngineCore

/// A scriptable engine: canned results, call counters, and an optional gate
/// that holds `listContainers` until released (to stage races).
final class MockEngine: ContainerEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _containers: Result<[Container], EngineError> = .success([])
    private var _status: Result<SystemStatus?, EngineError> = .success(MockEngine.running)
    private var _listCalls = 0
    private var _builderCalls = 0
    private var _gate: CheckedContinuation<Void, Never>?
    private var _holdNext = false

    static let running = try! JSONDecoder().decode(SystemStatus.self, from: Data(#"{"status":"running"}"#.utf8))

    var containers: Result<[Container], EngineError> {
        get { lock.withLock { _containers } }
        set { lock.withLock { _containers = newValue } }
    }
    var status: Result<SystemStatus?, EngineError> {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    var listCalls: Int { lock.withLock { _listCalls } }
    var builderCalls: Int { lock.withLock { _builderCalls } }

    /// The next `listContainers` call blocks until ``release()``.
    func holdNextList() { lock.withLock { _holdNext = true } }

    func release() {
        let gate = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { _gate = nil }
            return _gate
        }
        gate?.resume()
    }

    var isHolding: Bool { lock.withLock { _gate != nil } }

    func listContainers(all: Bool) async throws -> [Container] {
        let hold = lock.withLock { () -> Bool in
            _listCalls += 1
            defer { _holdNext = false }
            return _holdNext
        }
        // Snapshot the result at call time, as a real engine would.
        let result = containers
        if hold {
            await withCheckedContinuation { continuation in
                lock.withLock { _gate = continuation }
            }
        }
        return try result.get()
    }

    func systemStatus() async throws -> SystemStatus? { try status.get() }
    func builderStatus() async throws -> BuilderStatus {
        lock.withLock { _builderCalls += 1 }
        return BuilderStatus(isRunning: false, detail: nil)
    }
    func diskUsage() async throws -> SystemDiskUsage { throw EngineError.timedOut }
    func listImages() async throws -> [ContainerImage] { [] }
    func listVolumes() async throws -> [Volume] { [] }
    func volumeDiskUsage(_ name: String) async throws -> Int64 { 0 }
    func listNetworks() async throws -> [Network] { [] }

    func startServices() async throws {}
    func stopServices() async throws {}
    func systemProperties() async throws -> String { "" }
    func systemLogs(last: String) async throws -> String { "" }
    func inspectContainer(_ id: String) async throws -> Container { throw EngineError.notFound(id) }
    func startContainer(_ id: String) async throws {}
    func stopContainer(_ id: String, timeout: Int32?, signal: String?) async throws {}
    func waitContainer(_ id: String) async throws -> ContainerExit { ContainerExit(code: 0, exitedAt: nil) }
    func bootstrapContainer(_ id: String, stdio: ProcessStdio) async throws {}
    func createProcess(_ container: String, process: String, spec: ProcessSpec, stdio: ProcessStdio) async throws {}
    func startProcess(_ container: String, process: String) async throws {}
    func resizeProcess(_ container: String, process: String, width: Int, height: Int) async throws {}
    func waitProcess(_ container: String, process: String) async throws -> ContainerExit { ContainerExit(code: 0, exitedAt: nil) }
    func killContainer(_ id: String, signal: String?) async throws {}
    func deleteContainer(_ id: String, force: Bool) async throws {}
    func pruneContainers() async throws {}
    func runContainer(_ arguments: [String]) async throws {}
    func createContainer(_ arguments: [String]) async throws {}
    func execute(_ id: String, command: [String]) async throws -> Data { Data() }
    func copy(from source: String, to destination: String) async throws {}
    func inspectImage(_ reference: String) async throws -> ImageDetails { throw EngineError.notFound(reference) }
    func tagImage(_ source: String, as target: String) async throws {}
    func saveImages(_ references: [String], platform: String?, to path: String) async throws {}
    func loadImages(from path: String) async throws -> String { "" }
    func exportContainer(_ id: String, to path: String) async throws {}
    func recreateContainer(_ container: Container, edits: ContainerEdits) async throws {}
    func containerStats(_ id: String) async throws -> ContainerStats { throw EngineError.notFound(id) }
    func containerLogs(_ id: String, follow: Bool) -> AsyncThrowingStream<String, Error> { .init { $0.finish() } }
    func pullImage(_ reference: String) async throws {}
    func deleteImage(_ reference: String, force: Bool) async throws {}
    func pruneImages(all: Bool) async throws {}
    func pullImageWithProgress(_ reference: String, platform: String?) -> AsyncThrowingStream<String, Error> { .init { $0.finish() } }
    func buildImage(_ options: BuildOptions) -> AsyncThrowingStream<String, Error> { .init { $0.finish() } }
    func pushImage(_ reference: String) -> AsyncThrowingStream<String, Error> { .init { $0.finish() } }
    func createVolume(_ name: String) async throws {}
    func createVolume(_ name: String, labels: [String: String], size: String?, options: [String: String]) async throws {}
    func createNetwork(_ spec: NetworkSpec) async throws {}
    func deleteVolume(_ name: String) async throws {}
    func pruneVolumes() async throws {}
    func createNetwork(_ name: String, subnet: String?) async throws {}
    func deleteNetwork(_ name: String) async throws {}
    func pruneNetworks() async throws {}
    func listRegistryLogins() async throws -> [RegistryLogin] { [] }
    func registryLogin(server: String, username: String, password: String, scheme: RegistryScheme) async throws {}
    func registryLogout(server: String) async throws {}
}

func container(_ id: String, _ state: String) -> Container {
    let json = """
    {"id":"\(id)","status":{"state":"\(state)","networks":[]},"configuration":{"id":"\(id)",\
    "image":{"reference":"alpine","descriptor":{"digest":"d","mediaType":"m","size":1}},\
    "resources":{"cpus":1,"memoryInBytes":1},"platform":{"architecture":"arm64","os":"linux"},\
    "networks":[],"initProcess":{"executable":"sh","arguments":[],"workingDirectory":"/","environment":[]},\
    "labels":{},"creationDate":"2026-10-25T00:00:00Z","readOnly":false,"runtimeHandler":"r","rosetta":false}}
    """
    return try! JSONDecoder().decode(Container.self, from: Data(json.utf8))
}

final class EngineStoreTests: XCTestCase {

    /// Waits until `condition` holds (store work hops through tasks).
    private func eventually(_ timeout: Duration = .seconds(3),
                            _ condition: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition not met in time")
    }

    private func runningStore(_ engine: MockEngine, intervals: EngineStore.Intervals = .init()) async -> EngineStore {
        let store = EngineStore(engine: engine, intervals: intervals)
        await store.refresh(.system)
        return store
    }

    func testFirstLoadHasNoEventsThenChangesAreDiffed() async throws {
        let engine = MockEngine()
        engine.containers = .success([container("a", "running"), container("b", "stopped")])
        let store = await runningStore(engine)

        var updates = await store.updates().makeAsyncIterator()
        _ = await updates.next()   // current snapshot

        await store.refresh(.containers)
        let first = await updates.next()
        XCTAssertEqual(first?.events, [])
        XCTAssertEqual(first?.snapshot.containers.value?.map(\.id), ["a", "b"])

        engine.containers = .success([container("a", "stopped"), container("c", "running")])
        await store.refresh(.containers)
        let second = await updates.next()
        XCTAssertEqual(second?.events, [
            .containerStateChanged(id: "a", from: .running, to: .stopped),
            .containerCreated(id: "c"),
            .containerRemoved(id: "b"),
        ])
    }

    func testUnchangedResultsAreNotPublished() async throws {
        let engine = MockEngine()
        engine.containers = .success([container("a", "running")])
        let store = await runningStore(engine)

        var updates = await store.updates().makeAsyncIterator()
        _ = await updates.next()   // current snapshot

        await store.refresh(.containers)
        let first = await updates.next()
        XCTAssertEqual(first?.snapshot.containers.value?.map(\.id), ["a"])
        let loadedAt = try XCTUnwrap(first?.snapshot.containers.updatedAt)

        // The same answers again: subscribers hear nothing, yet the store
        // knows the data is fresh.
        try await Task.sleep(for: .milliseconds(20))
        await store.refresh(.containers)
        await store.refresh(.system)
        let updatedAt = await store.snapshot.containers.updatedAt
        XCTAssertGreaterThan(try XCTUnwrap(updatedAt), loadedAt)

        engine.containers = .success([container("b", "running")])
        await store.refresh(.containers)
        let next = await updates.next()
        XCTAssertEqual(next?.snapshot.containers.value?.map(\.id), ["b"],
                       "the unchanged fetches published nothing in between")
        XCTAssertEqual(next?.events, [.containerCreated(id: "b"), .containerRemoved(id: "a")])
    }

    func testErrorTransitionsArePublishedOnce() async throws {
        let engine = MockEngine()
        engine.containers = .success([container("a", "running")])
        let store = await runningStore(engine)
        await store.refresh(.containers)

        var updates = await store.updates().makeAsyncIterator()
        _ = await updates.next()

        engine.containers = .failure(.timedOut)
        await store.refresh(.containers)
        let failed = await updates.next()
        XCTAssertEqual(failed?.snapshot.containers.error, .timedOut)
        XCTAssertEqual(failed?.snapshot.containers.value?.map(\.id), ["a"])

        // The same failure again is not news; the recovery (to the same
        // value) is.
        await store.refresh(.containers)
        engine.containers = .success([container("a", "running")])
        await store.refresh(.containers)
        let recovered = await updates.next()
        XCTAssertNil(recovered?.snapshot.containers.error)
        XCTAssertEqual(recovered?.snapshot.containers.value?.map(\.id), ["a"])
    }

    func testSystemPollLeavesTheBuilderAlone() async throws {
        let engine = MockEngine()
        let store = await runningStore(engine)
        await store.refresh(.system)
        XCTAssertEqual(engine.builderCalls, 0, "builder status is a CLI spawn; nothing shows it")
    }

    func testConcurrentRefreshesCoalesce() async throws {
        let engine = MockEngine()
        let store = await runningStore(engine)

        engine.holdNextList()
        let first = Task { await store.refresh(.containers) }
        try await eventually { engine.isHolding }

        // Five more requests while the first fetch is in flight…
        let others = (0..<5).map { _ in Task { await store.refresh(.containers) } }
        try await Task.sleep(for: .milliseconds(50))
        engine.release()
        await first.value
        for task in others { await task.value }

        // …are served by exactly one follow-up fetch.
        XCTAssertEqual(engine.listCalls, 2)
    }

    func testRefreshDuringFlightReturnsFresherData() async throws {
        let engine = MockEngine()
        let store = await runningStore(engine)

        engine.containers = .success([container("old", "running")])
        engine.holdNextList()
        let inFlight = Task { await store.refresh(.containers) }
        try await eventually { engine.isHolding }

        // A mutation happens; its caller refreshes while the old fetch is pending.
        engine.containers = .success([container("new", "running")])
        let afterMutation = Task { await store.refresh(.containers) }
        try await Task.sleep(for: .milliseconds(50))
        engine.release()
        await afterMutation.value
        await inFlight.value

        let ids = await store.snapshot.containers.value?.map(\.id)
        XCTAssertEqual(ids, ["new"])
    }

    func testFailureKeepsLastGoodData() async throws {
        let engine = MockEngine()
        engine.containers = .success([container("a", "running")])
        let store = await runningStore(engine)
        await store.refresh(.containers)

        engine.containers = .failure(.timedOut)
        await store.refresh(.containers)
        var loadable = await store.snapshot.containers
        XCTAssertEqual(loadable.value?.map(\.id), ["a"])
        XCTAssertEqual(loadable.error, .timedOut)
        XCTAssertTrue(loadable.isStale)

        engine.containers = .success([])
        await store.refresh(.containers)
        loadable = await store.snapshot.containers
        XCTAssertNil(loadable.error)
        XCTAssertEqual(loadable.value?.count, 0)
    }

    func testStoppedServicesClearDataAndSkipFetches() async throws {
        let engine = MockEngine()
        engine.containers = .success([container("a", "running")])
        let store = await runningStore(engine)
        await store.refresh(.containers)

        var updates = await store.updates().makeAsyncIterator()
        _ = await updates.next()

        engine.status = .success(nil)
        await store.refresh(.system)
        let update = await updates.next()
        XCTAssertEqual(update?.events, [.servicesStopped])
        XCTAssertNil(update?.snapshot.containers.value)

        let calls = engine.listCalls
        await store.refresh(.containers)
        XCTAssertEqual(engine.listCalls, calls, "no container fetch while services are stopped")

        engine.status = .success(MockEngine.running)
        await store.refresh(.system)
        let restarted = await updates.next()
        XCTAssertEqual(restarted?.events, [.servicesStarted])
    }

    func testStatusErrorIsNotStopped() async throws {
        let engine = MockEngine()
        engine.status = .failure(.timedOut)
        let store = EngineStore(engine: engine)
        await store.refresh(.system)
        let service = await store.snapshot.service
        XCTAssertEqual(service, .failed(.timedOut))
    }

    func testPollingFollowsInterest() async throws {
        let engine = MockEngine()
        let intervals = EngineStore.Intervals(system: .milliseconds(30), containers: .milliseconds(30),
                                              others: .milliseconds(30))
        let store = await runningStore(engine, intervals: intervals)
        await store.startPolling()
        defer { Task { await store.stopPolling() } }

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(engine.listCalls, 0, "containers are not polled without interest")

        let token = await store.addInterest([.containers])
        try await eventually { engine.listCalls >= 3 }

        await store.removeInterest(token)
        try await Task.sleep(for: .milliseconds(60))
        let calls = engine.listCalls
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertLessThanOrEqual(engine.listCalls, calls + 1, "polling stops when interest goes away")
    }

    func testReplacedEngineDropsInFlightResult() async throws {
        let old = MockEngine()
        old.containers = .success([container("from-old", "running")])
        let store = await runningStore(old)

        old.holdNextList()
        let inFlight = Task { await store.refresh(.containers) }
        try await eventually { old.isHolding }

        let replacement = MockEngine()
        replacement.containers = .success([container("from-new", "running")])
        await store.replaceEngine(replacement)
        old.release()
        await inFlight.value

        await store.refresh(.system)
        await store.refresh(.containers)
        let ids = await store.snapshot.containers.value?.map(\.id)
        XCTAssertEqual(ids, ["from-new"])
    }
}
