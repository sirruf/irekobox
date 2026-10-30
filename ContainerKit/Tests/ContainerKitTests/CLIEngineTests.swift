import XCTest
@testable import ContainerKit

/// Records argv and replays canned output, so ``CLIEngine`` can be checked
/// against the exact `container` commands it issues.
private final class RecordingCLI: ContainerCommanding, @unchecked Sendable {
    var output = Data("[]".utf8)
    var error: EngineError?
    /// Fail only the calls this returns an error for.
    var failOn: (([String]) -> EngineError?)?
    private(set) var calls: [[String]] = []
    private(set) var inputs: [Data] = []

    func data(_ arguments: [String]) async throws -> Data {
        calls.append(arguments)
        if let error { throw error }
        return output
    }

    func decode<T: Decodable & Sendable>(_ type: T.Type, _ arguments: [String],
                                         alsoAccepting exitCodes: Set<Int32>) async throws -> T {
        try JSONDecoder().decode(T.self, from: await data(arguments))
    }

    func run(_ arguments: [String], workingDirectory: URL?) async throws {
        calls.append(arguments)
        if let error { throw error }
        if let failure = failOn?(arguments) { throw failure }
    }

    func run(_ arguments: [String], input: Data, workingDirectory: URL?) async throws {
        inputs.append(input)
        try await run(arguments, workingDirectory: workingDirectory)
    }
}

final class CLIEngineTests: XCTestCase {
    private var cli: RecordingCLI!
    private var engine: CLIEngine!

    override func setUp() {
        cli = RecordingCLI()
        engine = CLIEngine(cli: cli, stream: CLIStream())
    }

    func testContainerLifecycleArgv() async throws {
        _ = try await engine.listContainers(all: true)
        try await engine.startContainer("web")
        try await engine.stopContainer("web")
        try await engine.killContainer("web", signal: "SIGHUP")
        try await engine.deleteContainer("web", force: true)
        try await engine.pruneContainers()
        XCTAssertEqual(cli.calls, [
            ["list", "--format", "json", "--all"],
            ["start", "web"],
            ["stop", "web"],
            ["kill", "--signal", "SIGHUP", "web"],
            ["delete", "--force", "web"],
            ["prune"],
        ])
    }

    func testResourceArgv() async throws {
        try await engine.pullImage("nginx:latest")
        try await engine.deleteImage("nginx:latest", force: false)
        try await engine.createVolume("data")
        try await engine.deleteVolume("data")
        try await engine.createNetwork("net", subnet: "10.9.0.0/24")
        try await engine.deleteNetwork("net")
        try await engine.registryLogout(server: "registry.example.com")
        XCTAssertEqual(cli.calls, [
            ["image", "pull", "nginx:latest"],
            ["image", "delete", "nginx:latest"],
            ["volume", "create", "data"],
            ["volume", "delete", "data"],
            ["network", "create", "--subnet", "10.9.0.0/24", "net"],
            ["network", "delete", "net"],
            ["registry", "logout", "registry.example.com"],
        ])
    }

    func testRegistryPasswordGoesThroughStdinOnly() async throws {
        try await engine.registryLogin(server: "r.example.com", username: "me", password: "s3cret", scheme: .https)
        XCTAssertEqual(cli.calls.last, ["registry", "login", "r.example.com", "--username", "me",
                                        "--password-stdin", "--scheme", "https"])
        XCTAssertFalse(cli.calls.joined().contains { $0.contains("s3cret") })
        XCTAssertEqual(cli.inputs, [Data("s3cret\n".utf8)])
    }

    func testStoppedServicesMeanNilStatus() async throws {
        cli.error = .servicesNotRunning
        let status = try await engine.systemStatus()
        XCTAssertNil(status)
    }

    func testOtherStatusFailuresAreThrown() async throws {
        cli.error = .timedOut
        do {
            _ = try await engine.systemStatus()
            XCTFail("expected error")
        } catch let error as EngineError {
            XCTAssertEqual(error, .timedOut)
        }
    }

    func testRunContainer() async throws {
        try await engine.runContainer(["--detach", "--name", "web", "nginx"])
        XCTAssertEqual(cli.calls.last, ["run", "--detach", "--name", "web", "nginx"])
    }

    /// A failed edit must not lose the container: the original is run again.
    func testRecreateRollsBackWhenTheEditedContainerFails() async throws {
        let container = try JSONDecoder().decode(Container.self, from: Data("""
        {"id":"web","status":{"state":"running","networks":[]},"configuration":{"id":"web",        "image":{"reference":"nginx","descriptor":{"digest":"d","mediaType":"m","size":1}},        "resources":{"cpus":2,"memoryInBytes":1073741824},"platform":{"architecture":"arm64","os":"linux"},        "networks":[],"initProcess":{"executable":"nginx","arguments":[],"workingDirectory":"/","environment":["A=1"]},        "labels":{},"creationDate":"2026-10-25T00:00:00Z","readOnly":false,"runtimeHandler":"r","rosetta":false}}
        """.utf8))
        cli.failOn = { args in
            args.first == "run" && args.contains("BROKEN=1") ? .commandFailed(exitCode: 1, message: "bad flag") : nil
        }
        do {
            try await engine.recreateContainer(container, edits: ContainerEdits(environment: ["BROKEN=1"]))
            XCTFail("expected the edit to fail")
        } catch let error as EngineError {
            XCTAssertEqual(error, .rolledBack("bad flag"))
        }
        let runs = cli.calls.filter { $0.first == "run" }
        XCTAssertEqual(runs.count, 2, "edited run, then the original")
        XCTAssertTrue(runs[0].contains("BROKEN=1"))
        XCTAssertTrue(runs[1].contains("A=1"))
        XCTAssertFalse(runs[1].contains("BROKEN=1"))
    }

    func testInspectMissingContainerIsNotFound() async throws {
        do {
            _ = try await engine.inspectContainer("ghost")
            XCTFail("expected error")
        } catch let error as EngineError {
            guard case .notFound = error else { return XCTFail("got \(error)") }
        }
    }
}
