import XCTest
import Darwin
import ContainerKit
@testable import DockerAPIKit

/// Records calls; containers come from a real `container list` snapshot.
private final class FakeEngine: DockerBackend, @unchecked Sendable {
    var containers: [Container]
    /// Last exit per stopped container; absent → never ran ("invalidState").
    var exits: [String: ContainerExit] = [:]
    private(set) var calls: [String] = []
    private var waits = 0
    var waitCount: Int { lock.withLock { waits } }
    private let lock = NSLock()

    init(containers: [Container]) { self.containers = containers }

    private func record(_ call: String) { lock.withLock { calls.append(call) } }

    func systemStatus() async throws -> SystemStatus? { nil }
    func systemProperties() async throws -> String { "" }
    func listContainers(all: Bool) async throws -> [Container] { containers }
    func listImages() async throws -> [ContainerImage] { images }
    func startContainer(_ id: String) async throws { record("start \(id)") }
    func stopContainer(_ id: String, timeout: Int32?, signal: String?) async throws {
        record("stop \(id) t=\(timeout.map(String.init) ?? "-") s=\(signal ?? "-")")
    }
    func killContainer(_ id: String, signal: String?) async throws { record("kill \(id) \(signal ?? "-")") }
    func deleteContainer(_ id: String, force: Bool) async throws { record("delete \(id) force=\(force)") }
    func waitContainer(_ id: String) async throws -> ContainerExit {
        lock.withLock { waits += 1 }
        await Task.yield()
        if let exit = exits[id] { return exit }
        throw EngineError.serviceError(code: "invalidState", message: "no runtime client exists: container is stopped")
    }
    var images: [ContainerImage] = []
    var volumes: [String] = []
    func listVolumes() async throws -> [Volume] {
        try volumes.map { name in
            try JSONDecoder().decode(Volume.self, from: Data(#"{"id":"\#(name)","configuration":{"name":"\#(name)","driver":"local"}}"#.utf8))
        }
    }
    func createContainer(_ arguments: [String]) async throws { record("create \(arguments.joined(separator: " "))") }
    func createVolume(_ name: String) async throws { record("volume create \(name)") }
    func deleteVolume(_ name: String) async throws { record("volume delete \(name)") }
    func pullImage(_ reference: String, platform: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func containerLogs(_ id: String, follow: Bool) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func containerStats(_ id: String) async throws -> ContainerStats {
        ContainerStats(id: id, cpuUsageUsec: 0, memoryUsageBytes: 0, memoryLimitBytes: 0, networkRxBytes: 0,
                       networkTxBytes: 0, blockReadBytes: 0, blockWriteBytes: 0, numProcesses: 0)
    }
    // A start boots over XPC; record it like the CLI start it replaced.
    func bootstrapContainer(_ id: String, stdio: ProcessStdio) async throws { record("start \(id)") }
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

final class ContainersAPITests: XCTestCase {

    /// The snapshot; containers in `ran` get a start time (they ran before).
    private func fixture(ran: Set<String> = [], labels: [String: [String: String]] = [:]) throws -> [Container] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/container-list-1.6.1", withExtension: "json"))
        var list = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        for index in list.indices {
            guard let extra = labels[list[index]["id"] as? String ?? ""] else { continue }
            var configuration = list[index]["configuration"] as? [String: Any] ?? [:]
            let existing = configuration["labels"] as? [String: String] ?? [:]
            configuration["labels"] = existing.merging(extra) { $1 }
            list[index]["configuration"] = configuration
        }
        for index in list.indices where ran.contains(list[index]["id"] as? String ?? "") {
            var status = list[index]["status"] as? [String: Any] ?? [:]
            status["startedDate"] = "2026-10-26T00:00:00Z"
            list[index]["status"] = status
        }
        return try JSONDecoder().decode([Container].self, from: JSONSerialization.data(withJSONObject: list))
    }

    private func setUp(exits: [String: ContainerExit] = [:]) throws -> (DockerRouter, FakeEngine) {
        let engine = FakeEngine(containers: try fixture(ran: Set(exits.keys)))
        engine.exits = exits
        var router = DockerRouter()
        ContainersAPI.register(on: &router, backend: engine)
        return (router, engine)
    }

    private func call(_ router: DockerRouter, _ method: String, _ target: String) async -> HTTPResponse {
        await router.handle(HTTPRequest(method: method, target: target))
    }

    private func body(_ response: HTTPResponse) async throws -> Data {
        switch response.body {
        case .data(let data): return data
        case .stream(let stream):
            var data = Data()
            for try await chunk in stream { data.append(chunk) }
            return data
        case .hijack: return Data()
        }
    }

    private func jsonArray(_ response: HTTPResponse) async throws -> [[String: Any]] {
        let data = try await body(response)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func jsonObject(_ response: HTTPResponse) async throws -> [String: Any] {
        let data = try await body(response)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - IDs and states

    func testDockerIDsAreStableHexAndDifferPerContainer() throws {
        let containers = try fixture()
        let ids = containers.map(DockerContainer.id(for:))
        XCTAssertTrue(ids.allSatisfy { $0.count == 64 && $0.allSatisfy(\.isHexDigit) })
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids, try fixture().map(DockerContainer.id(for:)), "same container → same ID")
    }

    func testHumanDurationMatchesDocker() {
        XCTAssertEqual(HumanDuration.string(0.5), "Less than a second")
        XCTAssertEqual(HumanDuration.string(1), "1 second")
        XCTAssertEqual(HumanDuration.string(45), "45 seconds")
        XCTAssertEqual(HumanDuration.string(61), "About a minute")
        XCTAssertEqual(HumanDuration.string(5 * 60), "5 minutes")
        XCTAssertEqual(HumanDuration.string(3600), "About an hour")
        XCTAssertEqual(HumanDuration.string(5 * 3600), "5 hours")
        XCTAssertEqual(HumanDuration.string(3 * 86400), "3 days")
        XCTAssertEqual(HumanDuration.string(20 * 86400), "2 weeks")
        XCTAssertEqual(HumanDuration.string(90 * 86400), "3 months")
        XCTAssertEqual(HumanDuration.string(800 * 86400), "2 years")
    }

    // MARK: - List

    func testListShowsRunningByDefaultAndHidesSystemContainers() async throws {
        let (router, _) = try setUp(exits: ["ib-fx-stopped": ContainerExit(code: 7, exitedAt: Date().addingTimeInterval(-180))])
        let running = try await jsonArray(await call(router, "GET", "/v1.45/containers/json"))
        XCTAssertEqual(running.compactMap { ($0["Names"] as? [String])?.first }, ["/ib-fx-redis"])

        let all = try await jsonArray(await call(router, "GET", "/containers/json?all=1"))
        let names = all.compactMap { ($0["Names"] as? [String])?.first }
        XCTAssertEqual(Set(names), ["/ib-fx-redis", "/ib-fx-stopped"], "buildkit is a system container")

        let redis = try XCTUnwrap(all.first { ($0["Names"] as? [String])?.first == "/ib-fx-redis" })
        XCTAssertEqual(redis["Image"] as? String, "redis:7-alpine")
        XCTAssertEqual(redis["State"] as? String, "running")
        XCTAssertTrue((redis["Status"] as? String)?.hasPrefix("Up ") == true)
        let port = try XCTUnwrap((redis["Ports"] as? [[String: Any]])?.first)
        XCTAssertEqual(port["PrivatePort"] as? Int, 6379)
        XCTAssertEqual(port["PublicPort"] as? Int, 16379)
        XCTAssertEqual(port["Type"] as? String, "tcp")
        XCTAssertNotNil((redis["NetworkSettings"] as? [String: Any]).flatMap { $0["Networks"] as? [String: Any] }?["ib-fx-net"])

        let stopped = try XCTUnwrap(all.first { ($0["Names"] as? [String])?.first == "/ib-fx-stopped" })
        XCTAssertEqual(stopped["State"] as? String, "exited")
        XCTAssertEqual(stopped["Status"] as? String, "Exited (7) 3 minutes ago")
    }

    func testANeverStartedContainerIsCreated() async throws {
        let (router, _) = try setUp()
        let all = try await jsonArray(await call(router, "GET", "/containers/json?all=true"))
        let stopped = try XCTUnwrap(all.first { ($0["Names"] as? [String])?.first == "/ib-fx-stopped" })
        XCTAssertEqual(stopped["State"] as? String, "created")
        XCTAssertEqual(stopped["Status"] as? String, "Created")
    }

    func testListFilters() async throws {
        let (router, _) = try setUp()
        func names(_ filters: String) async throws -> [String] {
            let escaped = filters.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? filters
            return try await jsonArray(await call(router, "GET", "/containers/json?all=1&filters=\(escaped)"))
                .compactMap { ($0["Names"] as? [String])?.first }.sorted()
        }
        let byLabel = try await names(#"{"label":["app"]}"#)
        XCTAssertEqual(byLabel, ["/ib-fx-redis"])
        let byStatus = try await names(#"{"status":["created"]}"#)
        XCTAssertEqual(byStatus, ["/ib-fx-stopped"])
        let byName = try await names(#"{"name":{"redis":true}}"#)
        XCTAssertEqual(byName, ["/ib-fx-redis"], "legacy map form")
        let byAncestor = try await names(#"{"ancestor":["alpine"]}"#)
        XCTAssertEqual(byAncestor, ["/ib-fx-stopped"])
        let byNetwork = try await names(#"{"network":["ib-fx-net"]}"#)
        XCTAssertEqual(byNetwork, ["/ib-fx-redis"])
        let byPort = try await names(#"{"publish":["16379"]}"#)
        XCTAssertEqual(byPort, ["/ib-fx-redis"])

        let bad = await call(router, "GET", "/containers/json?filters=%7B%22nope%22%3A%5B%5D%7D")
        XCTAssertEqual(bad.status, 400)
    }

    // MARK: - Inspect and resolve

    func testInspectByNameIdAndPrefix() async throws {
        let (router, _) = try setUp()
        let id = DockerContainer.id(for: try fixture().first { $0.id == "ib-fx-redis" }!)
        for reference in ["ib-fx-redis", "%2Fib-fx-redis", id, String(id.prefix(12))] {
            let response = await call(router, "GET", "/containers/\(reference)/json")
            XCTAssertEqual(response.status, 200, reference)
            let inspect = try await jsonObject(response)
            XCTAssertEqual(inspect["Id"] as? String, id)
            XCTAssertEqual(inspect["Name"] as? String, "/ib-fx-redis")
        }
        let inspect = try await jsonObject(await call(router, "GET", "/containers/ib-fx-redis/json"))
        let state = try XCTUnwrap(inspect["State"] as? [String: Any])
        XCTAssertEqual(state["Status"] as? String, "running")
        XCTAssertEqual(state["Running"] as? Bool, true)
        XCTAssertEqual(state["FinishedAt"] as? String, "0001-01-01T00:00:00Z")
        let ports = try XCTUnwrap((inspect["NetworkSettings"] as? [String: Any])?["Ports"] as? [String: [[String: String]]])
        XCTAssertEqual(ports["6379/tcp"]?.first?["HostPort"], "16379")
        // Compose recreates a container whose NetworkID isn't the network's ID.
        let networks = try XCTUnwrap((inspect["NetworkSettings"] as? [String: Any])?["Networks"] as? [String: [String: Any]])
        XCTAssertFalse(networks.isEmpty)
        for (name, endpoint) in networks {
            XCTAssertEqual(endpoint["NetworkID"] as? String, NetworkDirectory.id(name))
        }

        let missing = await call(router, "GET", "/containers/nope/json")
        XCTAssertEqual(missing.status, 404)
        let message = try await jsonObject(missing)["message"] as? String
        XCTAssertEqual(message, "No such container: nope")
    }

    /// Compose waits on `condition: service_healthy` only when inspect
    /// reports the healthcheck in Config, not just State.Health.
    func testInspectReportsTheHealthcheck() async throws {
        let health = #"{"Test":["CMD","pg_isready"],"Interval":5000000000,"Retries":5}"#
        let engine = FakeEngine(containers: try fixture(labels: ["ib-fx-redis": [DockerLabels.healthcheck: health]]))
        var router = DockerRouter()
        ContainersAPI.register(on: &router, backend: engine)
        let inspect = try await jsonObject(await call(router, "GET", "/containers/ib-fx-redis/json"))
        let config = try XCTUnwrap(inspect["Config"] as? [String: Any])
        let check = try XCTUnwrap(config["Healthcheck"] as? [String: Any])
        XCTAssertEqual(check["Test"] as? [String], ["CMD", "pg_isready"])
        XCTAssertEqual(check["Retries"] as? Int, 5)

        let (plain, _) = try setUp()
        let other = try await jsonObject(await call(plain, "GET", "/containers/ib-fx-redis/json"))
        XCTAssertNil((other["Config"] as? [String: Any])?["Healthcheck"] as? [String: Any])
    }

    // MARK: - Lifecycle

    func testLifecycleCallsAndDockerStatusCodes() async throws {
        let (router, engine) = try setUp(exits: ["ib-fx-stopped": ContainerExit(code: 0, exitedAt: Date())])
        do { let status = await call(router, "POST", "/containers/ib-fx-redis/start").status; XCTAssertEqual(status, 304, "already running") }
        do { let status = await call(router, "POST", "/containers/ib-fx-stopped/stop").status; XCTAssertEqual(status, 304, "already stopped") }
        do { let status = await call(router, "POST", "/containers/ib-fx-stopped/kill").status; XCTAssertEqual(status, 409) }
        do { let status = await call(router, "DELETE", "/containers/ib-fx-redis").status; XCTAssertEqual(status, 409, "running without force") }

        do { let status = await call(router, "POST", "/containers/ib-fx-stopped/start").status; XCTAssertEqual(status, 204) }
        do { let status = await call(router, "POST", "/containers/ib-fx-redis/stop?t=3&signal=SIGINT").status; XCTAssertEqual(status, 204) }
        do { let status = await call(router, "POST", "/containers/ib-fx-redis/kill?signal=SIGHUP").status; XCTAssertEqual(status, 204) }
        do { let status = await call(router, "POST", "/containers/ib-fx-redis/restart").status; XCTAssertEqual(status, 204) }
        do { let status = await call(router, "DELETE", "/containers/ib-fx-redis?force=1").status; XCTAssertEqual(status, 204) }
        XCTAssertEqual(engine.calls, [
            "start ib-fx-stopped",
            "stop ib-fx-redis t=3 s=SIGINT",
            "kill ib-fx-redis SIGHUP",
            "stop ib-fx-redis t=- s=-", "start ib-fx-redis",
            "delete ib-fx-redis force=true",
        ])
    }

    func testPruneRemovesStoppedOnly() async throws {
        let (router, engine) = try setUp()
        let report = try await jsonObject(await call(router, "POST", "/containers/prune"))
        XCTAssertEqual((report["ContainersDeleted"] as? [String])?.count, 1)
        XCTAssertEqual(engine.calls, ["delete ib-fx-stopped force=false"])
    }

    func testWaitOnAnExitedContainerAnswersAtOnce() async throws {
        let (router, _) = try setUp(exits: ["ib-fx-stopped": ContainerExit(code: 3, exitedAt: Date())])
        let response = await call(router, "POST", "/containers/ib-fx-stopped/wait")
        XCTAssertEqual(response.status, 200)
        let result = try await jsonObject(response)
        XCTAssertEqual(result["StatusCode"] as? Int, 3)
        do { let status = await call(router, "POST", "/containers/ib-fx-stopped/wait?condition=bogus").status; XCTAssertEqual(status, 400) }
    }

    func testARunWhoseExitWasMissedIsExitedWithoutACode() async throws {
        let engine = FakeEngine(containers: try fixture(ran: ["ib-fx-stopped"]))   // no recorded exit
        var router = DockerRouter()
        ContainersAPI.register(on: &router, backend: engine)
        let all = try await jsonArray(await call(router, "GET", "/containers/json?all=1"))
        let stopped = try XCTUnwrap(all.first { ($0["Names"] as? [String])?.first == "/ib-fx-stopped" })
        XCTAssertEqual(stopped["State"] as? String, "exited")
        XCTAssertEqual(stopped["Status"] as? String, "Exited", "no invented exit code")
    }

    // MARK: - Exit recorder

    func testMissedExitIsQueriedOncePerRun() async throws {
        let engine = FakeEngine(containers: try fixture(ran: ["ib-fx-stopped"]))
        let stopped = try XCTUnwrap(engine.containers.first { $0.id == "ib-fx-stopped" })
        let recorder = ExitRecorder(backend: engine)
        let directory = ContainerDirectory(backend: engine, exits: recorder)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let item = await directory.describe(stopped)
                    XCTAssertEqual(item.state, .exited)
                    XCTAssertNil(item.exit)
                }
            }
        }
        _ = try await directory.all()
        _ = try await directory.resolve(stopped.id)
        XCTAssertEqual(engine.waitCount, 1)

        let nextRun = try JSONDecoder().decode(Container.self, from: JSONEncoder().encode(stopped)
            .replacing(Data("2026-10-26T00:00:00Z".utf8), with: Data("2026-10-26T09:00:00Z".utf8)))
        _ = await directory.describe(nextRun)
        XCTAssertEqual(engine.waitCount, 2, "a later run gets its own lookup")

        await recorder.record(ContainerExit(code: 7, exitedAt: nil), for: stopped)
        let recorded = await directory.describe(stopped)
        XCTAssertEqual(recorded.exit?.code, 7, "a real record supersedes a missed lookup")
        XCTAssertEqual(engine.waitCount, 2)
    }

    func testConcurrentDescriptionsShareSuccessfulExitLookup() async throws {
        let engine = FakeEngine(containers: try fixture(ran: ["ib-fx-stopped"]))
        let stopped = try XCTUnwrap(engine.containers.first { $0.id == "ib-fx-stopped" })
        engine.exits[stopped.id] = ContainerExit(code: 12, exitedAt: nil)
        let directory = ContainerDirectory(backend: engine, exits: ExitRecorder(backend: engine))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let item = await directory.describe(stopped)
                    XCTAssertEqual(item.exit?.code, 12)
                }
            }
        }
        XCTAssertEqual(engine.waitCount, 1)
    }

    func testRecorderForgetsMissesForRemovedContainers() async throws {
        let engine = FakeEngine(containers: try fixture(ran: ["ib-fx-stopped"]))
        let stopped = try XCTUnwrap(engine.containers.first { $0.id == "ib-fx-stopped" })
        let recorder = ExitRecorder(backend: engine)
        let directory = ContainerDirectory(backend: engine, exits: recorder)
        _ = await directory.describe(stopped)
        engine.containers = []
        await recorder.scan()
        _ = await directory.describe(stopped)
        XCTAssertEqual(engine.waitCount, 2)
    }

    func testMissedExitIsNotPersistedAndDefaultDirectoryCachesIt() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "ib-exits-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = FakeEngine(containers: try fixture(ran: ["ib-fx-stopped"]))
        let stopped = try XCTUnwrap(engine.containers.first { $0.id == "ib-fx-stopped" })
        let redis = try XCTUnwrap(engine.containers.first { $0.id == "ib-fx-redis" })
        let recorder = ExitRecorder(backend: engine, file: file)
        let directory = ContainerDirectory(backend: engine, exits: recorder)
        _ = await directory.describe(stopped)
        await recorder.record(ContainerExit(code: 3, exitedAt: nil), for: redis)
        let saved = try JSONDecoder().decode([String: ExitRecorder.Record].self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.count, 1)
        let reloaded = ContainerDirectory(backend: engine, exits: ExitRecorder(backend: engine, file: file))
        _ = await reloaded.describe(stopped)
        XCTAssertEqual(engine.waitCount, 2, "an agent restart retries missed exits")

        let fallback = ContainerDirectory(backend: engine)
        _ = await fallback.describe(stopped)
        _ = await fallback.describe(stopped)
        XCTAssertEqual(engine.waitCount, 3)
    }

    func testRecorderCatchesExitsOfRunningContainersAndPersistsThem() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "ib-exits-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = FakeEngine(containers: try fixture())
        let redis = try XCTUnwrap(engine.containers.first { $0.id == "ib-fx-redis" })
        engine.exits = ["ib-fx-redis": ContainerExit(code: 137, exitedAt: Date(timeIntervalSince1970: 1_800_000_000))]

        let recorder = ExitRecorder(backend: engine, file: file)
        await recorder.scan()        // starts a wait on the running redis; the fake returns at once
        try await Task.sleep(for: .milliseconds(100))
        let seen = await recorder.exit(for: redis)
        XCTAssertEqual(seen?.code, 137)

        // A new recorder (agent restart) still knows it, for the same run only.
        let reloaded = ExitRecorder(backend: engine, file: file)
        let remembered = await reloaded.exit(for: redis)
        XCTAssertEqual(remembered?.code, 137)
        let nextRun = try JSONDecoder().decode(Container.self, from: JSONEncoder().encode(redis)
            .replacing(Data("2026-10-26T00:01:34Z".utf8), with: Data("2026-10-26T09:00:00Z".utf8)))
        let other = await reloaded.exit(for: nextRun)
        XCTAssertNil(other, "a later run doesn't inherit the old code")
    }

    // MARK: - Create

    private func image(_ reference: String) throws -> ContainerImage {
        let json = #"{"id":"x","configuration":{"name":"\#(reference)","descriptor":{"digest":"sha256:1","mediaType":"m","size":1}}}"#
        return try JSONDecoder().decode(ContainerImage.self, from: Data(json.utf8))
    }

    func testCreateChecksTheNameAndTheImage() async throws {
        let (router, engine) = try setUp()
        engine.images = [try image("docker.io/library/alpine:latest")]
        func post(_ target: String, _ body: String) async -> HTTPResponse {
            await router.handle(HTTPRequest(method: "POST", target: target, body: Data(body.utf8)))
        }
        let clash = await post("/containers/create?name=ib-fx-redis", #"{"Image":"alpine"}"#)
        XCTAssertEqual(clash.status, 409)
        let missing = await post("/containers/create?name=new1", #"{"Image":"nginx:alpine"}"#)
        XCTAssertEqual(missing.status, 404)
        let missingMessage = try await jsonObject(missing)["message"] as? String
        XCTAssertEqual(missingMessage, "No such image: nginx:alpine", "docker run pulls on exactly this")
        let invalid = await post("/containers/create?name=-bad", #"{"Image":"alpine"}"#)
        XCTAssertEqual(invalid.status, 400)

        // Valid: created through the engine, then looked up (the fake's list
        // doesn't grow, so resolving the new name fails with 404 here).
        _ = await post("/containers/create?name=new1", #"{"Image":"alpine","Volumes":{"/data":{}}}"#)
        XCTAssertEqual(engine.calls.first, "volume create new1-anon-\(CreateMapping.anonymousVolumeName(container: "new1", path: "/data").dropFirst("new1-anon-".count))")
        let create = try XCTUnwrap(engine.calls.first { $0.hasPrefix("create --name new1 ") })
        XCTAssertTrue(create.contains(" -v new1-anon-") && create.contains(":/data "), create)
        XCTAssertTrue(create.contains(" --network default ") && create.hasSuffix(" alpine"), create)
    }

    func testANamedVolumeTheCreateMakesIsFilledFromTheImage() async throws {
        let (router, engine) = try setUp()
        engine.images = [try image("docker.io/library/postgres:17-alpine")]
        engine.volumes = ["kept"]
        let body = #"{"Image":"postgres:17-alpine","HostConfig":{"Binds":["pgdata:/var/lib/postgresql/data","kept:/kept"]}}"#
        _ = await router.handle(HTTPRequest(method: "POST", target: "/containers/create?name=new2", body: Data(body.utf8)))
        let helpers = engine.calls.filter { $0.hasPrefix("create --name new2-copyup-") }
        XCTAssertEqual(helpers.count, 1, "only the volume that didn't exist: \(engine.calls)")
        XCTAssertTrue(helpers[0].contains(" -v pgdata:/.irekobox-copyup "), helpers[0])
        XCTAssertTrue(helpers[0].contains("/var/lib/postgresql/data"), helpers[0])
    }

    func testATakenPortIsReportedInDockersWords() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, size) }
        }
        try XCTSkipIf(bound != 0, "binding is not allowed here")
        XCTAssertEqual(listen(listener, 1), 0)
        var length = size
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))
        var list = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try fixture())) as! [[String: Any]]
        var configuration = list[0]["configuration"] as! [String: Any]
        configuration["publishedPorts"] = [["containerPort": 5432, "hostPort": port, "proto": "tcp"]]
        list[0]["configuration"] = configuration
        let container = try JSONDecoder().decode([Container].self, from: JSONSerialization.data(withJSONObject: list))[0]

        struct RuntimeError: Error, CustomStringConvertible {
            var description: String { #"failed to bootstrap container (cause: "unknown: "bind(descriptor:ptr:bytes:): Address already in use) (errno: 48)")"# }
        }
        let error = try XCTUnwrap(ContainersAPI.portConflict(RuntimeError(), container))
        XCTAssertTrue(error.message.contains("Bind for 0.0.0.0:\(port) failed: port is already allocated"), error.message)
        struct Other: Error {}
        XCTAssertNil(ContainersAPI.portConflict(Other(), container), "other start errors pass through")
    }

    func testAMissingBindSourceIsNamed() throws {
        var list = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try fixture())) as! [[String: Any]]
        var configuration = list[0]["configuration"] as! [String: Any]
        configuration["mounts"] = [["destination": "/data", "source": "/nonexistent-irekobox-test", "options": [String]()]]
        list[0]["configuration"] = configuration
        let container = try JSONDecoder().decode([Container].self, from: JSONSerialization.data(withJSONObject: list))[0]
        XCTAssertThrowsError(try ContainersAPI.checkMountSources(container)) { error in
            XCTAssertTrue((error as? DockerAPIError)?.message.contains("/nonexistent-irekobox-test") == true)
        }
    }

    func testRemoveWithVolumesDeletesAnonymousOnes() async throws {
        let engine = FakeEngine(containers: try fixture())
        var list = try JSONSerialization.jsonObject(with: JSONEncoder().encode(engine.containers)) as! [[String: Any]]
        for index in list.indices where list[index]["id"] as? String == "ib-fx-stopped" {
            var configuration = list[index]["configuration"] as! [String: Any]
            configuration["labels"] = [DockerLabels.anonymousVolumes: "ib-fx-stopped-anon-a,ib-fx-stopped-anon-b"]
            list[index]["configuration"] = configuration
        }
        engine.containers = try JSONDecoder().decode([Container].self, from: JSONSerialization.data(withJSONObject: list))
        var router = DockerRouter()
        ContainersAPI.register(on: &router, backend: engine)
        let status = await call(router, "DELETE", "/containers/ib-fx-stopped?v=1").status
        XCTAssertEqual(status, 204)
        XCTAssertEqual(engine.calls, ["delete ib-fx-stopped force=false",
                                      "volume delete ib-fx-stopped-anon-a", "volume delete ib-fx-stopped-anon-b"])
    }
}
