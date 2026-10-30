import XCTest
import ContainerKit
@testable import DockerAPIKit

/// Volumes, networks and containers from captured 1.6.1 shapes; records calls.
private final class ResourceEngine: DockerBackend, @unchecked Sendable {
    var containers: [Container] = []
    var volumes: [Volume] = []
    var networks: [Network] = []
    private(set) var calls: [String] = []
    private let lock = NSLock()
    private func record(_ call: String) { lock.withLock { calls.append(call) } }

    func listContainers(all: Bool) async throws -> [Container] { containers }
    func listVolumes() async throws -> [Volume] { volumes }
    func createVolume(_ name: String, labels: [String: String], size: String?) async throws {
        record("volume create \(name) labels=\(labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }) size=\(size ?? "-")")
        volumes.append(try ResourceEngine.volume(name, labels: labels))
    }
    func deleteVolume(_ name: String) async throws {
        record("volume delete \(name)")
        volumes.removeAll { $0.name == name }
    }
    func volumeDiskUsage(_ name: String) async throws -> Int64 { 1000 }
    func listNetworks() async throws -> [Network] { networks }
    func createNetwork(_ spec: NetworkSpec) async throws {
        record("network create \(spec.name) subnet=\(spec.subnet ?? "-") v6=\(spec.subnetV6 ?? "-") hostOnly=\(spec.hostOnly)")
        networks.append(try ResourceEngine.network(spec.name, labels: spec.labels))
    }
    func deleteNetwork(_ name: String) async throws {
        record("network delete \(name)")
        networks.removeAll { $0.name == name }
    }

    static func volume(_ name: String, labels: [String: String] = [:]) throws -> Volume {
        let json = try JSONSerialization.data(withJSONObject: [
            "id": name,
            "configuration": ["name": name, "driver": "local", "format": "ext4", "labels": labels,
                              "creationDate": "2026-10-26T09:00:00Z", "options": [String: String](),
                              "source": "/vol/\(name)/volume.img", "sizeInBytes": 1 << 30] as [String: Any],
        ])
        return try JSONDecoder().decode(Volume.self, from: json)
    }

    static func network(_ name: String, labels: [String: String] = [:], builtin: Bool = false) throws -> Network {
        var all = labels
        if builtin { all["com.apple.container.resource.role"] = "builtin" }
        let json = try JSONSerialization.data(withJSONObject: [
            "id": name,
            "configuration": ["name": name, "mode": "nat", "labels": all, "creationDate": "2026-10-26T09:00:00Z"] as [String: Any],
            "status": ["ipv4Gateway": "192.168.66.1", "ipv4Subnet": "192.168.66.0/24"],
        ])
        return try JSONDecoder().decode(Network.self, from: json)
    }

    func systemStatus() async throws -> SystemStatus? { nil }
    func systemProperties() async throws -> String { "" }
    func listImages() async throws -> [ContainerImage] { [] }
    func startContainer(_ id: String) async throws {}
    func stopContainer(_ id: String, timeout: Int32?, signal: String?) async throws {}
    func killContainer(_ id: String, signal: String?) async throws {}
    func deleteContainer(_ id: String, force: Bool) async throws {}
    func waitContainer(_ id: String) async throws -> ContainerExit { ContainerExit(code: 0, exitedAt: nil) }
    func createContainer(_ arguments: [String]) async throws {}
    func createVolume(_ name: String) async throws {}
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

final class VolumesNetworksTests: XCTestCase {

    /// ib-fx-redis (running) uses network ib-fx-net and volume ib-fx-vol.
    private func setUp() throws -> (DockerRouter, ResourceEngine) {
        let engine = ResourceEngine()
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/container-list-1.6.1", withExtension: "json"))
        engine.containers = try JSONDecoder().decode([Container].self, from: Data(contentsOf: fixture))
        engine.volumes = [try ResourceEngine.volume("ib-fx-vol"), try ResourceEngine.volume("spare", labels: ["team": "a"]),
                          try ResourceEngine.volume("web-anon-1a2b3c4d5e")]
        engine.networks = [try ResourceEngine.network("default", builtin: true), try ResourceEngine.network("ib-fx-net"),
                           try ResourceEngine.network("idle", labels: ["team": "a"])]
        var router = DockerRouter()
        VolumesAPI.register(on: &router, backend: engine)
        NetworksAPI.register(on: &router, backend: engine)
        return (router, engine)
    }

    private func json(_ response: HTTPResponse) throws -> Any {
        guard case .data(let data) = response.body else { return [:] }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func filter(_ json: String) -> String {
        json.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? json
    }

    // MARK: - Volumes

    func testVolumeListFiltersDanglingAndLabels() async throws {
        let (router, _) = try setUp()
        func names(_ query: String) async throws -> [String] {
            let response = await router.handle(HTTPRequest(method: "GET", target: "/volumes" + query))
            let body = try XCTUnwrap(try json(response) as? [String: Any])
            return (body["Volumes"] as? [[String: Any]] ?? []).compactMap { $0["Name"] as? String }.sorted()
        }
        let all = try await names("")
        XCTAssertEqual(all, ["ib-fx-vol", "spare", "web-anon-1a2b3c4d5e"])
        let dangling = try await names("?filters=" + filter(#"{"dangling":["true"]}"#))
        XCTAssertEqual(dangling, ["spare", "web-anon-1a2b3c4d5e"])
        let labelled = try await names("?filters=" + filter(#"{"label":["team=a"]}"#))
        XCTAssertEqual(labelled, ["spare"])
    }

    func testVolumeCreateIsIdempotentAndRefusesOtherDrivers() async throws {
        let (router, engine) = try setUp()
        let created = await router.handle(HTTPRequest(method: "POST", target: "/volumes/create",
            body: Data(#"{"Name":"db","Labels":{"app":"x"},"DriverOpts":{"size":"2G"}}"#.utf8)))
        XCTAssertEqual(created.status, 201)
        let again = await router.handle(HTTPRequest(method: "POST", target: "/volumes/create", body: Data(#"{"Name":"db"}"#.utf8)))
        XCTAssertEqual(again.status, 201)
        XCTAssertEqual(engine.calls, ["volume create db labels=[\"app=x\"] size=2G"])
        let nfs = await router.handle(HTTPRequest(method: "POST", target: "/volumes/create",
            body: Data(#"{"Name":"n","DriverOpts":{"type":"nfs"}}"#.utf8)))
        XCTAssertEqual(nfs.status, 400)
        let plugin = await router.handle(HTTPRequest(method: "POST", target: "/volumes/create",
            body: Data(#"{"Name":"n","Driver":"rexray"}"#.utf8)))
        XCTAssertEqual(plugin.status, 400)
    }

    func testVolumeInUseCantBeRemovedAndPruneTakesAnonymousOnlyByDefault() async throws {
        let (router, engine) = try setUp()
        let busy = await router.handle(HTTPRequest(method: "DELETE", target: "/volumes/ib-fx-vol"))
        XCTAssertEqual(busy.status, 409)
        let missing = await router.handle(HTTPRequest(method: "DELETE", target: "/volumes/nope?force=1"))
        XCTAssertEqual(missing.status, 204)

        let pruneResponse = await router.handle(HTTPRequest(method: "POST", target: "/v1.47/volumes/prune"))
        let prune = try XCTUnwrap(try json(pruneResponse) as? [String: Any])
        XCTAssertEqual(prune["VolumesDeleted"] as? [String], ["web-anon-1a2b3c4d5e"])
        let allResponse = await router.handle(HTTPRequest(method: "POST",
            target: "/v1.47/volumes/prune?filters=" + filter(#"{"all":["true"]}"#)))
        let all = try XCTUnwrap(try json(allResponse) as? [String: Any])
        XCTAssertEqual(all["VolumesDeleted"] as? [String], ["spare"])
        XCTAssertFalse(engine.calls.contains("volume delete ib-fx-vol"))
    }

    // MARK: - Networks

    func testNetworkListShowsBridgeHostAndNone() async throws {
        let (router, _) = try setUp()
        let listResponse = await router.handle(HTTPRequest(method: "GET", target: "/networks"))
        let list = try XCTUnwrap(try json(listResponse) as? [[String: Any]])
        XCTAssertEqual(list.compactMap { $0["Name"] as? String }, ["bridge", "ib-fx-net", "idle", "host", "none"])
        let net = try XCTUnwrap(list.first { $0["Name"] as? String == "ib-fx-net" })
        let containers = try XCTUnwrap(net["Containers"] as? [String: [String: Any]])
        XCTAssertEqual(containers.values.first?["Name"] as? String, "ib-fx-redis")

        let customResponse = await router.handle(HTTPRequest(method: "GET",
            target: "/networks?filters=" + filter(#"{"type":["custom"]}"#)))
        let custom = try XCTUnwrap(try json(customResponse) as? [[String: Any]])
        XCTAssertEqual(custom.compactMap { $0["Name"] as? String }, ["ib-fx-net", "idle"])
        let byDefaultName = await router.handle(HTTPRequest(method: "GET", target: "/networks/default"))
        XCTAssertEqual((try json(byDefaultName) as? [String: Any])?["Name"] as? String, "bridge")
    }

    func testNetworkCreateRemoveAndPrune() async throws {
        let (router, engine) = try setUp()
        let created = await router.handle(HTTPRequest(method: "POST", target: "/networks/create", body: Data(#"""
        {"Name":"app","Driver":"bridge","Internal":true,"IPAM":{"Config":[{"Subnet":"10.9.0.0/24"},{"Subnet":"fd00:9::/64"}]}}
        """#.utf8)))
        XCTAssertEqual(created.status, 201)
        XCTAssertEqual((try json(created) as? [String: Any])?["Id"] as? String, NetworkDirectory.id("app"))
        let duplicate = await router.handle(HTTPRequest(method: "POST", target: "/networks/create", body: Data(#"{"Name":"app"}"#.utf8)))
        XCTAssertEqual(duplicate.status, 409)
        let overlay = await router.handle(HTTPRequest(method: "POST", target: "/networks/create", body: Data(#"{"Name":"o","Driver":"overlay"}"#.utf8)))
        XCTAssertEqual(overlay.status, 400)

        let builtin = await router.handle(HTTPRequest(method: "DELETE", target: "/networks/bridge"))
        XCTAssertEqual(builtin.status, 403)
        let busy = await router.handle(HTTPRequest(method: "DELETE", target: "/networks/ib-fx-net"))
        XCTAssertEqual(busy.status, 409)

        let pruneResponse = await router.handle(HTTPRequest(method: "POST",
            target: "/networks/prune?filters=" + filter(#"{"label":["team=a"]}"#)))
        let prune = try XCTUnwrap(try json(pruneResponse) as? [String: Any])
        XCTAssertEqual(prune["NetworksDeleted"] as? [String], ["idle"])
        XCTAssertEqual(engine.calls, ["network create app subnet=10.9.0.0/24 v6=fd00:9::/64 hostOnly=true", "network delete idle"])
    }

    func testConnectOnlyWhatIsAlreadyThere() async throws {
        let (router, _) = try setUp()
        let same = await router.handle(HTTPRequest(method: "POST", target: "/networks/ib-fx-net/connect",
                                                   body: Data(#"{"Container":"ib-fx-redis"}"#.utf8)))
        XCTAssertEqual(same.status, 200)
        let other = await router.handle(HTTPRequest(method: "POST", target: "/networks/idle/connect",
                                                    body: Data(#"{"Container":"ib-fx-redis"}"#.utf8)))
        XCTAssertEqual(other.status, 409)
    }

    // MARK: - Events

    func testContainerDiffsBecomeDockerEvents() async throws {
        let engine = ResourceEngine()
        let hub = EventHub(backend: engine)
        let now = Date()
        func state(_ name: String, running: Bool, started: String?) -> EventHub.ContainerState {
            .init(id: "id-\(name)", name: name, image: "alpine", labels: ["k": "v"], running: running, started: started)
        }
        let old = ["id-a": state("a", running: true, started: "t1"), "id-b": state("b", running: false, started: nil),
                   "id-c": state("c", running: true, started: "t1")]
        let new = ["id-a": state("a", running: false, started: "t1"), "id-b": state("b", running: true, started: "t2"),
                   "id-c": state("c", running: true, started: "t2"), "id-d": state("d", running: true, started: "t3")]
        let events = await hub.containerEvents(old, new, now)
        XCTAssertEqual(events.map { "\($0.action) \($0.attributes["name"]!)" },
                       ["die a", "start b", "die c", "start c", "create d", "start d"])
        XCTAssertEqual(events.first?.attributes["k"], "v")
        XCTAssertEqual(events.first?.attributes["exitCode"], "0")

        let gone = await hub.containerEvents(["id-a": state("a", running: true, started: "t1")], [:], now)
        XCTAssertEqual(gone.map(\.action), ["die", "destroy"])
    }

    func testEventFiltersAndWireShape() throws {
        let event = DockerEvent(type: "container", action: "start", actorID: "abc123",
                                attributes: ["name": "web", "image": "nginx", "com.docker.compose.project": "app"],
                                time: Date(timeIntervalSince1970: 1_800_000_000.5))
        func filters(_ json: String) throws -> DockerFilters { try DockerFilters(query: json) }
        XCTAssertTrue(EventsAPI.matches(event, try filters(#"{"type":["container"],"event":["start","die"]}"#)))
        XCTAssertTrue(EventsAPI.matches(event, try filters(#"{"container":["web"]}"#)))
        XCTAssertTrue(EventsAPI.matches(event, try filters(#"{"label":["com.docker.compose.project=app"]}"#)))
        XCTAssertFalse(EventsAPI.matches(event, try filters(#"{"type":["image"]}"#)))
        XCTAssertFalse(EventsAPI.matches(event, try filters(#"{"container":["db"]}"#)))

        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event.wire)) as? [String: Any])
        XCTAssertEqual(wire["Type"] as? String, "container")
        XCTAssertEqual(wire["status"] as? String, "start")
        XCTAssertEqual(wire["from"] as? String, "nginx")
        XCTAssertEqual(wire["time"] as? Int, 1_800_000_000)
        XCTAssertEqual((wire["Actor"] as? [String: Any])?["ID"] as? String, "abc123")
    }

    func testTimeFiltersTakeSecondsDatesAndDurations() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(DockerTime.moment("1700000000.5", now: now)?.timeIntervalSince1970, 1_700_000_000.5)
        XCTAssertEqual(DockerTime.moment("1h30m", now: now)?.timeIntervalSince1970, 10_000 - 5400)
        XCTAssertEqual(DockerTime.moment("90s", now: now)?.timeIntervalSince1970, 10_000 - 90)
        XCTAssertNotNil(DockerTime.moment("2026-10-26T09:00:00Z", now: now))
        XCTAssertNil(DockerTime.moment("soon", now: now))
        XCTAssertNil(DockerTime.moment("10", now: now).flatMap { $0.timeIntervalSince1970 == 10 ? nil : $0 })
    }
}

final class HostsSyncTests: XCTestCase {
    private func container(_ name: String, networks: [(String, String)], labels: [String: String] = [:]) throws -> Container {
        let json = try JSONSerialization.data(withJSONObject: [
            "id": name,
            "status": ["state": "running", "startedDate": "2026-10-26T10:00:00Z",
                       "networks": networks.map { ["network": $0.0, "ipv4Address": "\($0.1)/24"] }] as [String: Any],
            "configuration": [
                "id": name, "labels": labels, "creationDate": "2026-10-26T10:00:00Z", "readOnly": false,
                "runtimeHandler": "container-runtime-linux", "rosetta": false,
                "image": ["reference": "docker.io/library/alpine:latest",
                          "descriptor": ["digest": "sha256:x", "mediaType": "m", "size": 1]],
                "resources": ["cpus": 1, "memoryInBytes": 1 << 30],
                "platform": ["os": "linux", "architecture": "arm64"],
                "networks": networks.map { ["network": $0.0] },
                "initProcess": ["executable": "/bin/sh", "arguments": [String](), "environment": [String](),
                                "workingDirectory": "/", "terminal": false,
                                "user": ["id": ["uid": 0, "gid": 0]], "supplementalGroups": [Int](),
                                "rlimits": [String]()] as [String: Any],
            ] as [String: Any],
        ])
        return try JSONDecoder().decode(Container.self, from: json)
    }

    /// Machines learn each other's names and the containers beside them.
    func testMachinesListTheDefaultNetwork() throws {
        let machine = ["com.apple.container.plugin": "machine"]
        let ubuntu = try container("ubuntu-24-04-e9db04", networks: [("default", "192.168.66.146")], labels: machine)
        let fedora = try container("fedora-41-1a2b3c", networks: [("default", "192.168.66.150")], labels: machine)
        let node = try container("dev", networks: [("default", "192.168.66.124")])
        let elsewhere = try container("app-web-1", networks: [("app_front", "10.1.0.3")])
        let files = Dictionary(uniqueKeysWithValues: HostsSync.machineFiles(for: [ubuntu, fedora, node, elsewhere])
            .map { ($0.0.id, $0.1) })
        XCTAssertEqual(Set(files.keys), ["ubuntu-24-04-e9db04", "fedora-41-1a2b3c"])
        let hosts = try XCTUnwrap(files["ubuntu-24-04-e9db04"])
        let lines = hosts.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[3], "192.168.66.146\tubuntu-24-04 ubuntu-24-04.machine", "itself first")
        XCTAssertTrue(lines.contains("192.168.66.124\tdev"))
        XCTAssertTrue(lines.contains("192.168.66.150\tfedora-41 fedora-41.machine"))
        XCTAssertFalse(hosts.contains("app-web-1"), "other networks aren't reachable")
    }

    func testNeighboursGetTheAddressOnTheSharedNetwork() throws {
        let web = try container("app-web-1", networks: [("app_front", "10.1.0.3")],
                                labels: [DockerLabels.aliases: #"{"app_front":["web"]}"#])
        let cache = try container("app-cache-1", networks: [("app_back", "10.2.0.2"), ("app_front", "10.1.0.2")],
                                  labels: [DockerLabels.aliases: #"{"app_back":["cache"],"app_front":["cache"]}"#])
        let loner = try container("loner", networks: [("default", "192.168.66.9")])
        let files = Dictionary(uniqueKeysWithValues: HostsSync.files(for: [web, cache, loner]).map { ($0.0.id, $0.1) })

        XCTAssertNil(files["loner"], "the default network gets no names, as in Docker")
        let webHosts = try XCTUnwrap(files["app-web-1"])
        XCTAssertTrue(webHosts.contains("10.1.0.3\tapp-web-1 web\n"))
        XCTAssertTrue(webHosts.contains("10.1.0.2\tcache app-cache-1\n"), "front address, not back")
        XCTAssertFalse(webHosts.contains("10.2.0.2"))
        let cacheHosts = try XCTUnwrap(files["app-cache-1"])
        XCTAssertTrue(cacheHosts.contains("10.2.0.2\tapp-cache-1 cache\n"))
        XCTAssertTrue(cacheHosts.contains("10.1.0.3\tweb app-web-1\n"))
    }

    /// Slow copies; the containers it lists can change between rounds.
    private final class Neighbours: DockerBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var _containers: [Container] = []
        private var _copies: [String] = []
        var containers: [Container] {
            get { lock.withLock { _containers } }
            set { lock.withLock { _containers = newValue } }
        }
        var copies: [String] { lock.withLock { _copies } }
        func copy(from source: String, to destination: String) async throws {
            try await Task.sleep(for: .milliseconds(150))
            lock.withLock { _copies.append(destination) }
        }
        /// Files are written by running `cat > /etc/hosts` in the container.
        func createProcess(_ container: String, process: String, spec: ProcessSpec, stdio: ProcessStdio) async throws {
            try await Task.sleep(for: .milliseconds(150))
            lock.withLock { _copies.append("\(container):/etc/hosts") }
        }
        func listContainers(all: Bool) async throws -> [Container] { containers }
        func waitContainer(_ id: String) async throws -> ContainerExit { ContainerExit(code: 0, exitedAt: nil) }
        func systemStatus() async throws -> SystemStatus? { nil }
        func systemProperties() async throws -> String { "" }
        func listImages() async throws -> [ContainerImage] { [] }
        func startContainer(_ id: String) async throws {}
        func stopContainer(_ id: String, timeout: Int32?, signal: String?) async throws {}
        func killContainer(_ id: String, signal: String?) async throws {}
        func deleteContainer(_ id: String, force: Bool) async throws {}
        func createContainer(_ arguments: [String]) async throws {}
        func createVolume(_ name: String) async throws {}
        func deleteVolume(_ name: String) async throws {}
        func pullImage(_ reference: String, platform: String?) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
        func containerLogs(_ id: String, follow: Bool) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
        func containerStats(_ id: String) async throws -> ContainerStats { throw EngineError.notFound(id) }
        func bootstrapContainer(_ id: String, stdio: ProcessStdio) async throws {}
        func startProcess(_ container: String, process: String) async throws {}
        func resizeProcess(_ container: String, process: String, width: Int, height: Int) async throws {}
        func waitProcess(_ container: String, process: String) async throws -> ContainerExit { ContainerExit(code: 0, exitedAt: nil) }
        func execute(_ id: String, command: [String]) async throws -> Data { Data() }
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

    /// A start that comes while another round is writing must not return
    /// before its own file is written (nginx resolves its upstreams at once).
    func testSyncWaitsForARoundThatSeesTheCaller() async throws {
        let engine = Neighbours()
        let backend = try container("app-backend-1", networks: [("app_default", "10.4.0.2")],
                                    labels: ["com.docker.compose.service": "backend"])
        engine.containers = [backend]
        let hosts = HostsSync(backend: engine)
        let first = Task { await hosts.sync() }
        try await Task.sleep(for: .milliseconds(50))    // the first round is copying now
        engine.containers = [backend, try container("app-web-1", networks: [("app_default", "10.4.0.3")])]
        await hosts.sync()
        XCTAssertTrue(engine.copies.contains("app-web-1:/etc/hosts"), "web's file is written before its start returns")
        await first.value
    }

    func testComposeServiceLabelIsTheFallbackAlias() throws {
        let db = try container("shop-db-1", networks: [("shop_default", "10.3.0.2")],
                               labels: ["com.docker.compose.service": "db"])
        let api = try container("shop-api-1", networks: [("shop_default", "10.3.0.3")])
        let files = Dictionary(uniqueKeysWithValues: HostsSync.files(for: [db, api]).map { ($0.0.id, $0.1) })
        XCTAssertTrue(try XCTUnwrap(files["shop-api-1"]).contains("10.3.0.2\tdb shop-db-1\n"))
    }
}

final class ExitWaitsTests: XCTestCase {
    private final class Waiter: DockerBackend, @unchecked Sendable {
        func waitContainer(_ id: String) async throws -> ContainerExit { ContainerExit(code: 3, exitedAt: nil) }
        func systemStatus() async throws -> SystemStatus? { nil }
        func systemProperties() async throws -> String { "" }
        func listContainers(all: Bool) async throws -> [Container] { [] }
        func listImages() async throws -> [ContainerImage] { [] }
        func startContainer(_ id: String) async throws {}
        func stopContainer(_ id: String, timeout: Int32?, signal: String?) async throws {}
        func killContainer(_ id: String, signal: String?) async throws {}
        func deleteContainer(_ id: String, force: Bool) async throws {}
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

    func testAnExpectedRunHandsItsExitToTheWaiter() async {
        let waits = ExitWaits()
        let notExpected = await waits.isExpected("web")
        XCTAssertFalse(notExpected)
        await waits.expect("web")
        let expected = await waits.isExpected("web")
        XCTAssertTrue(expected)
        await waits.begin("web", backend: Waiter())
        let exit = await waits.run("web")?.value
        XCTAssertEqual(exit?.code, 3)
        await waits.done("web")
        let after = await waits.run("web")
        XCTAssertNil(after, "forgotten once nobody waits")
    }
}
