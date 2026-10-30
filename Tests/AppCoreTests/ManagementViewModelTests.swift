import XCTest
import ContainerKit
import EngineCore
@testable import AppCore

@MainActor
final class ImagesViewModelTests: XCTestCase {
    func testLoadDecodes() async {
        let mock = MockCLI()
        mock.responder = { _ in Data(Fixtures.images.utf8) }
        let (engine, model) = mock.engineAndModel()
        let vm = ImagesViewModel(engine: engine, model: model)
        await vm.load()
        XCTAssertEqual(vm.images.count, 1)
        XCTAssertEqual(vm.images.first?.shortName, "alpine:latest")
        XCTAssertNil(vm.error)
    }

    /// A name searches Docker Hub; choosing one fills in "name:" and lists
    /// its tags, newest first, narrowed by what follows the colon.
    func testPullSuggestions() async {
        let (engine, model) = MockCLI().engineAndModel()
        let registry = RegistryClient { request in
            let url = request.url!
            XCTAssertEqual(url.path, "/v2/library/postgres/tags/list")
            return (Data(#"{"tags":["16","17-alpine","latest","17","alpine"]}"#.utf8),
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let vm = ImagesViewModel(engine: engine, model: model, search: { term, _ in
            [SearchResult(name: term == "postg" ? "postgres" : "?", description: "", star_count: 1,
                          is_official: true, is_automated: false)]
        }, registry: registry)
        await vm.loadSuggestions(for: "postg")
        XCTAssertEqual(vm.suggestions.map(\.completion), ["postgres:"])
        await vm.loadSuggestions(for: "postgres:")
        XCTAssertEqual(vm.suggestions.map(\.completion),
                       ["postgres:latest", "postgres:17", "postgres:17-alpine", "postgres:16", "postgres:alpine"])
        await vm.loadSuggestions(for: "postgres:17")
        XCTAssertEqual(vm.suggestions.map(\.completion), ["postgres:17", "postgres:17-alpine"])
    }

    /// Images on this Mac that match come before Docker Hub's results.
    func testSuggestionsOfferLocalImagesFirst() async {
        let suggester = ImageSuggester(search: { _, _ in
            [SearchResult(name: "nginx", description: "", star_count: 1, is_official: true, is_automated: false)]
        })
        await suggester.load(for: "ngi", local: ["docker.io/library/nginx:alpine", "redis:7"])
        XCTAssertEqual(suggester.suggestions.map(\.completion), ["docker.io/library/nginx:alpine", "nginx:"])
    }

    /// Pull streams progress from `container image pull --progress plain`,
    /// limited to the native platform unless amd64 is asked for.
    func testPullStreamsProgressForTheNativePlatform() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ib-pull-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let argsFile = dir.appendingPathComponent("args")
        let script = dir.appendingPathComponent("container")
        try """
        #!/bin/sh
        echo "$@" >> '\(argsFile.path)'
        echo '[1/2] Fetching image 50% (2 of 4 blobs, 1.0/2.0 MB, 1 MB/s) [1s]'
        echo '[2/2] Unpacking image 100% (10 entries, 2.0 MB) [2s]' >&2
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let mock = MockCLI()
        let engine = CLIEngine(cli: mock, stream: CLIStream(binaryPath: script.path))
        let vm = ImagesViewModel(engine: engine, model: EngineModel(source: EngineStore(engine: engine)))
        vm.pullReference = "nginx:latest"
        await vm.pull()
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.pullReference, "", "cleared after a successful pull")
        XCTAssertEqual(try String(contentsOf: argsFile, encoding: .utf8),
                       "image pull --progress plain --platform linux/arm64 nginx:latest\n")

        vm.pullReference = "nginx:latest"
        vm.pullAMD64 = true
        await vm.pull()
        let calls = try String(contentsOf: argsFile, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(calls.suffix(2), ["image pull --progress plain --platform linux/arm64 nginx:latest",
                                         "image pull --progress plain --platform linux/amd64 nginx:latest"])
    }

    func testUnusedImagesAndUsage() async {
        let mock = MockCLI()
        mock.responder = { args in
            if args.starts(with: ["image", "ls"]) { return Data(Fixtures.images.utf8) }
            if args.starts(with: ["list"]) { return Data(Fixtures.containers.utf8) }
            return Data("[]".utf8)
        }
        let (engine, model) = mock.engineAndModel()
        let vm = ImagesViewModel(engine: engine, model: model)
        await model.refresh([.images, .containers])
        // The fixture container runs "nginx", not alpine: alpine is unused.
        XCTAssertEqual(vm.unused.map(\.shortName), ["alpine:latest"])
        XCTAssertEqual(vm.usedBy(vm.images[0]), [])
    }

    func testDeleteCallsCLI() async {
        let mock = MockCLI()
        mock.responder = { _ in Data(Fixtures.images.utf8) }
        let (engine, model) = mock.engineAndModel()
        let vm = ImagesViewModel(engine: engine, model: model)
        await vm.load()
        await vm.delete(vm.images[0])
        XCTAssertTrue(mock.didRun(["image", "delete", "docker.io/library/alpine:latest"]))
    }

    func testLoadErrorSurfaces() async {
        let mock = MockCLI()
        mock.responder = { _ in Data("not json".utf8) }
        let (engine, model) = mock.engineAndModel()
        let vm = ImagesViewModel(engine: engine, model: model)
        await vm.load()
        XCTAssertNotNil(vm.error)
    }
}

@MainActor
final class VolumesViewModelTests: XCTestCase {
    func testLoadAndCreate() async {
        let mock = MockCLI()
        mock.responder = { _ in Data(Fixtures.volumes.utf8) }
        let (engine, model) = mock.engineAndModel()
        let vm = VolumesViewModel(engine: engine, model: model)
        await vm.load()
        XCTAssertEqual(vm.volumes.map(\.name), ["data"])

        vm.newName = "cache"
        await vm.create()
        XCTAssertTrue(mock.didRun(["volume", "create", "cache"]))
        XCTAssertEqual(vm.newName, "")
    }

    func testDelete() async {
        let mock = MockCLI()
        mock.responder = { _ in Data(Fixtures.volumes.utf8) }
        let (engine, model) = mock.engineAndModel()
        let vm = VolumesViewModel(engine: engine, model: model)
        await vm.load()
        await vm.delete(vm.volumes[0])
        XCTAssertTrue(mock.didRun(["volume", "delete", "data"]))
    }
}

@MainActor
final class NetworksViewModelTests: XCTestCase {
    func testLoadAndBuiltinFlag() async {
        let mock = MockCLI()
        mock.responder = { _ in Data(Fixtures.networks.utf8) }
        let (engine, model) = mock.engineAndModel()
        let vm = NetworksViewModel(engine: engine, model: model)
        await vm.load()
        XCTAssertEqual(vm.networks.count, 2)
        XCTAssertTrue(vm.networks.first { $0.name == "default" }?.isBuiltin ?? false)
        XCTAssertFalse(vm.networks.first { $0.name == "mynet" }?.isBuiltin ?? true)
    }

    func testCreateWithSubnet() async {
        let mock = MockCLI()
        let (engine, model) = mock.engineAndModel()
        let vm = NetworksViewModel(engine: engine, model: model)
        vm.newName = "mynet"
        vm.newSubnet = "10.10.0.0/24"
        await vm.create()
        XCTAssertTrue(mock.didRun(["network", "create", "--subnet", "10.10.0.0/24", "mynet"]))
    }

    func testCreateWithoutSubnet() async {
        let mock = MockCLI()
        let (engine, model) = mock.engineAndModel()
        let vm = NetworksViewModel(engine: engine, model: model)
        vm.newName = "plain"
        await vm.create()
        XCTAssertTrue(mock.didRun(["network", "create", "plain"]))
    }
}

@MainActor
final class ContainersViewModelTests: XCTestCase {
    func testLoadAndActions() async {
        let mock = MockCLI()
        mock.responder = { _ in Data(Fixtures.containers.utf8) }
        let (engine, model) = mock.engineAndModel()
        let vm = ContainersViewModel(engine: engine, model: model)
        await vm.load()
        XCTAssertEqual(vm.containers.count, 1)
        let web = vm.containers[0]
        XCTAssertTrue(web.state.isRunning)

        await vm.stop(web)
        XCTAssertTrue(mock.didRun(["stop", "web"]))
        await vm.delete(web)
        XCTAssertTrue(mock.didRun(["delete", "--force", "web"]))
    }
}

@MainActor
final class ResourceUsageTests: XCTestCase {
    /// A container mounting volume `data` and attached to network `mynet`.
    nonisolated private static let user = """
    [{"id":"db","status":{"networks":[],"state":"running"},"configuration":{"id":"db",\
    "image":{"reference":"postgres","descriptor":{"digest":"d","mediaType":"m","size":1}},\
    "resources":{"cpus":1,"memoryInBytes":1},"platform":{"architecture":"arm64","os":"linux"},\
    "networks":[{"network":"mynet"}],"initProcess":{"executable":"postgres","arguments":[],"workingDirectory":"/","environment":[]},\
    "labels":{},"creationDate":"2026-10-25T00:00:00Z","readOnly":false,"runtimeHandler":"r","rosetta":false,\
    "mounts":[{"destination":"/var/lib/postgresql/data","source":"/x/volume.img","options":[],"type":{"volume":{"name":"data"}}}]}}]
    """

    private func mock() -> MockCLI {
        let mock = MockCLI()
        mock.responder = { args in
            if args.starts(with: ["volume", "ls"]) { return Data(Fixtures.volumes.utf8) }
            if args.starts(with: ["network", "ls"]) { return Data(Fixtures.networks.utf8) }
            if args.starts(with: ["list"]) { return Data(Self.user.utf8) }
            return Data("[]".utf8)
        }
        return mock
    }

    func testVolumeAndNetworkUsers() async {
        let (engine, model) = mock().engineAndModel()
        await model.refresh([.volumes, .networks, .containers])
        let volumes = VolumesViewModel(engine: engine, model: model)
        let networks = NetworksViewModel(engine: engine, model: model)
        XCTAssertEqual(volumes.usedBy(volumes.volumes[0]), ["db"])
        XCTAssertEqual(networks.usedBy(networks.networks.first { $0.name == "mynet" }!), ["db"])
        XCTAssertEqual(networks.usedBy(networks.networks.first { $0.name == "default" }!), [])
    }
}
