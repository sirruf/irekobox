import XCTest
import ContainerKit
@testable import MCPKit

final class MockEngine: ContainerEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _containers: Result<[Container], EngineError> = .success([])
    private var _status: Result<SystemStatus?, EngineError> = .success(MockEngine.running)
    private var _listCalls = 0
    private var _gate: CheckedContinuation<Void, Never>?
    private var _holdNext = false
    var started: [String] = []
    var deleted: [String] = []
    private var _built: [BuildOptions] = []
    private var _buildEnded = false
    var built: [BuildOptions] { lock.withLock { _built } }
    var buildEnded: Bool { lock.withLock { _buildEnded } }
    /// Builds stay running until the stream is cancelled or ``finishBuild()``.
    var holdBuilds = false
    private var buildContinuation: AsyncThrowingStream<String, Error>.Continuation?
    /// What the next build prints, and how it ends.
    var buildLines: [String] = []
    var buildError: Error?

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
    func builderStatus() async throws -> BuilderStatus { BuilderStatus(isRunning: false, detail: nil) }
    func diskUsage() async throws -> SystemDiskUsage { throw EngineError.timedOut }
    func listImages() async throws -> [ContainerImage] { [] }
    func listVolumes() async throws -> [Volume] { [] }
    func volumeDiskUsage(_ name: String) async throws -> Int64 { 0 }
    func listNetworks() async throws -> [Network] { [] }

    func startServices() async throws {}
    func stopServices() async throws {}
    func systemProperties() async throws -> String { "" }
    func systemLogs(last: String) async throws -> String { "" }
    func inspectContainer(_ id: String) async throws -> Container {
        guard let match = try containers.get().first(where: { $0.id == id }) else { throw EngineError.notFound(id) }
        return match
    }
    func startContainer(_ id: String) async throws { lock.withLock { started.append(id) } }
    func stopContainer(_ id: String, timeout: Int32?, signal: String?) async throws {}
    func waitContainer(_ id: String) async throws -> ContainerExit { ContainerExit(code: 0, exitedAt: nil) }
    func bootstrapContainer(_ id: String, stdio: ProcessStdio) async throws {}
    func createProcess(_ container: String, process: String, spec: ProcessSpec, stdio: ProcessStdio) async throws {}
    func startProcess(_ container: String, process: String) async throws {}
    func resizeProcess(_ container: String, process: String, width: Int, height: Int) async throws {}
    func waitProcess(_ container: String, process: String) async throws -> ContainerExit { ContainerExit(code: 0, exitedAt: nil) }
    func killContainer(_ id: String, signal: String?) async throws {}
    func deleteContainer(_ id: String, force: Bool) async throws { lock.withLock { deleted.append(id) } }
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
    func buildImage(_ options: BuildOptions) -> AsyncThrowingStream<String, Error> {
        lock.withLock { _built.append(options) }
        let lines = buildLines, error = buildError, hold = holdBuilds
        return .init { continuation in
            continuation.onTermination = { [self] _ in lock.withLock { _buildEnded = true } }
            lines.forEach { continuation.yield($0) }
            if hold {
                lock.withLock { buildContinuation = continuation }
            } else {
                continuation.finish(throwing: error)
            }
        }
    }

    func finishBuild() { lock.withLock { buildContinuation }?.finish() }
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

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: [String] { lock.withLock { lines } }
    func append(_ line: String) { lock.withLock { lines.append(line) } }
}

struct Deny: Approver { func approve(assistant: String, action: String) async -> Bool { false } }

/// Says no, and keeps what it was asked.
final class Recorder: Approver, @unchecked Sendable {
    private(set) var asked: [String] = []
    func approve(assistant: String, action: String) async -> Bool { asked.append(action); return false }
}

final class MCPServerTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func server(level: AccessLevel?, ask: Bool = true, approver: Approver = AlwaysApprove(),
                        engine: MockEngine = MockEngine(), progressInterval: Duration = .seconds(5)) throws -> MCPServer {
        var settings = AssistantSettings()
        settings.askBeforeDeleting = ask
        var key: String?
        if let level {
            let assistant = Assistant(name: "Tester", client: "custom", level: level)
            settings.assistants = [assistant]
            key = assistant.key
        }
        try AssistantFiles.save(settings, to: folder.appending(path: "assistants.json"))
        return MCPServer(context: ToolContext(engine: engine, cli: ContainerCLI(binaryPath: "/nonexistent")), key: key,
                         settingsURL: folder.appending(path: "assistants.json"),
                         activityURL: folder.appending(path: "activity.jsonl"), approver: approver,
                         progressInterval: progressInterval)
    }

    private func send(_ server: MCPServer, _ method: String, _ params: JSON = [:], id: Int = 1) async -> JSON {
        let line: JSON = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
        let reply = await server.handle(line.line())
        return reply.flatMap(JSON.parse) ?? .null
    }

    private func toolNames(_ reply: JSON) -> Set<String> {
        Set(reply["result"]?["tools"]?.array?.compactMap { $0["name"]?.string } ?? [])
    }

    func testInitializeNamesTheServerAndTheLevel() async throws {
        let server = try server(level: .operate)
        let reply = await send(server, "initialize", ["protocolVersion": "2025-06-18", "clientInfo": ["name": "test"]])
        XCTAssertEqual(reply["result"]?["serverInfo"]?["name"]?.string, "irekobox")
        XCTAssertEqual(reply["result"]?["protocolVersion"]?.string, "2025-06-18")
        XCTAssertTrue(reply["result"]?["instructions"]?.string?.contains("Look and operate") == true)
    }

    func testNotificationsGetNoReply() async throws {
        let server = try server(level: .lookOnly)
        let reply = await server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(reply)
    }

    func testToolsFollowTheLevel() async throws {
        let look = toolNames(await send(try server(level: .lookOnly), "tools/list"))
        XCTAssertTrue(look.contains("list_containers"))
        XCTAssertFalse(look.contains("restart_container"))
        let operate = toolNames(await send(try server(level: .operate), "tools/list"))
        XCTAssertTrue(operate.contains("restart_container"))
        XCTAssertFalse(operate.contains("delete_container"))
        let everything = toolNames(await send(try server(level: .everything), "tools/list"))
        XCTAssertTrue(everything.contains("delete_container"))
    }

    func testUnknownKeyGetsTheNewAssistantLevel() async throws {
        let names = toolNames(await send(try server(level: nil), "tools/list"))
        XCTAssertFalse(names.contains("start_container"), "no key → Look only by default")
    }

    func testCallAboveTheLevelIsRefusedAndLogged() async throws {
        let engine = MockEngine()
        let server = try server(level: .lookOnly, engine: engine)
        let reply = await send(server, "tools/call", ["name": "start_container", "arguments": ["name": "web"]])
        XCTAssertEqual(reply["result"]?["isError"]?.bool, true)
        XCTAssertTrue(engine.started.isEmpty)
        let log = ActivityLog.read(from: folder.appending(path: "activity.jsonl"))
        XCTAssertEqual(log.first?.outcome, .refused)
    }

    func testAllowedCallRunsTheTool() async throws {
        let engine = MockEngine()
        let server = try server(level: .operate, engine: engine)
        let reply = await send(server, "tools/call", ["name": "start_container", "arguments": ["name": "web"]])
        XCTAssertEqual(reply["result"]?["isError"]?.bool, false)
        XCTAssertEqual(engine.started, ["web"])
        XCTAssertEqual(ActivityLog.read(from: folder.appending(path: "activity.jsonl")).first?.summary, "started web")
    }

    private func buildCall(_ arguments: JSON) -> JSON { ["name": "build_image", "arguments": arguments] }

    private func text(_ reply: JSON) -> String {
        reply["result"]?["content"]?.array?.first?["text"]?.string ?? ""
    }

    func testBuildingNeedsEverything() async throws {
        let engine = MockEngine()
        let operate = try server(level: .operate, engine: engine)
        let names = toolNames(await send(operate, "tools/list"))
        XCTAssertFalse(names.contains("build_image"))
        let reply = await send(operate, "tools/call", buildCall(["context": .string(folder.path), "tag": "app:dev"]))
        XCTAssertEqual(reply["result"]?["isError"]?.bool, true)
        XCTAssertTrue(engine.built.isEmpty)
    }

    func testBuildUsesTheDockerfileInTheContext() async throws {
        try Data().write(to: folder.appending(path: "Dockerfile"))
        let engine = MockEngine()
        let server = try server(level: .everything, engine: engine)
        let reply = await send(server, "tools/call", buildCall([
            "context": .string(folder.path), "tag": "app:dev", "build_args": ["MODE=dev"], "target": "web", "no_cache": true,
        ]))
        XCTAssertEqual(reply["result"]?["isError"]?.bool, false)
        XCTAssertEqual(text(reply), "Built app:dev.")
        let options = try XCTUnwrap(engine.built.first)
        XCTAssertEqual(options.contextPath, folder.path)
        XCTAssertEqual(options.dockerfilePath, folder.appending(path: "Dockerfile").path)
        XCTAssertEqual(options.buildArguments, ["MODE=dev"])
        XCTAssertEqual(options.target, "web")
        XCTAssertTrue(options.noCache)
        XCTAssertEqual(ActivityLog.read(from: folder.appending(path: "activity.jsonl")).first?.summary, "built app:dev")
    }

    func testBuildResolvesARelativeDockerfileAgainstTheContext() throws {
        let nested = folder.appending(path: "docker")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appending(path: "api.Dockerfile"))
        let options = try ContainerTools.buildOptions([
            "context": .string(folder.path), "tag": "app:dev", "dockerfile": "docker/api.Dockerfile",
        ])
        XCTAssertEqual(options.dockerfilePath, nested.appending(path: "api.Dockerfile").path)
    }

    func testBuildFallsBackToContainerfile() throws {
        try Data().write(to: folder.appending(path: "Containerfile"))
        let options = try ContainerTools.buildOptions(["context": .string(folder.path), "tag": "app:dev"])
        XCTAssertEqual(options.dockerfilePath, folder.appending(path: "Containerfile").path)
    }

    func testBuildRefusesWhatItCantFindWithoutBuilding() async throws {
        let engine = MockEngine()
        let server = try server(level: .everything, engine: engine)
        for (context, expected) in [("relative/path", "full path"), ("/no/such/folder", "No folder"),
                                    (folder.path, "No Dockerfile or Containerfile")] {
            let reply = await send(server, "tools/call", buildCall(["context": .string(context), "tag": "app:dev"]))
            XCTAssertEqual(reply["result"]?["isError"]?.bool, true)
            XCTAssertTrue(text(reply).contains(expected), text(reply))
        }
        XCTAssertTrue(engine.built.isEmpty)
    }

    func testBuildFailureShowsTheFailingStep() async throws {
        try Data().write(to: folder.appending(path: "Dockerfile"))
        let engine = MockEngine()
        engine.buildLines = ["#5 [2/2] RUN make", "#5 ERROR: exit code 2"]
        engine.buildError = EngineError.timedOut
        let server = try server(level: .everything, engine: engine)
        let reply = await send(server, "tools/call", buildCall(["context": .string(folder.path), "tag": "app:dev"]))
        XCTAssertEqual(reply["result"]?["isError"]?.bool, true)
        XCTAssertTrue(text(reply).contains("#5 ERROR: exit code 2"), text(reply))
        XCTAssertEqual(ActivityLog.read(from: folder.appending(path: "activity.jsonl")).first?.outcome, .failed)
    }

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func heldBuild() throws -> (MockEngine, JSON) {
        try Data().write(to: folder.appending(path: "Dockerfile"))
        let engine = MockEngine()
        engine.holdBuilds = true
        engine.buildLines = ["#3 [1/2] FROM alpine"]
        return (engine, buildCall(["context": .string(folder.path), "tag": "app:dev"]))
    }

    func testCancellingABuildStopsItAndSendsNoReply() async throws {
        let (engine, call) = try heldBuild()
        let server = try server(level: .everything, engine: engine)
        let request: JSON = ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": call]
        let reply = Task { await server.handle(request.line()) }
        try await until { !engine.built.isEmpty }
        let cancel: JSON = ["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 7]]
        let answer = await server.handle(cancel.line())
        XCTAssertNil(answer)
        let result = await reply.value
        XCTAssertNil(result)
        XCTAssertTrue(engine.buildEnded)
        XCTAssertEqual(ActivityLog.read(from: folder.appending(path: "activity.jsonl")).first?.outcome, .failed)
    }

    func testProgressReportsTheLatestLineWhileABuildRuns() async throws {
        let (engine, call) = try heldBuild()
        let server = try server(level: .everything, engine: engine, progressInterval: .milliseconds(10))
        let sent = Lines()
        let params: JSON = ["name": "build_image", "arguments": call["arguments"] ?? [:], "_meta": ["progressToken": "t1"]]
        let request: JSON = ["jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": params]
        let reply = Task { await server.handle(request.line(), notify: sent.append) }
        try await until { sent.all.count >= 2 }
        engine.finishBuild()
        let result = await reply.value
        XCTAssertTrue(result?.contains("Built app:dev.") == true)
        let notes = sent.all.compactMap(JSON.parse)
        XCTAssertEqual(notes.first?["method"]?.string, "notifications/progress")
        XCTAssertEqual(notes.first?["params"]?["progressToken"]?.string, "t1")
        XCTAssertEqual(notes.first?["params"]?["message"]?.string, "#3 [1/2] FROM alpine")
        XCTAssertEqual(notes.first?["params"]?["progress"]?.int, 1)
        XCTAssertEqual(notes.dropFirst().first?["params"]?["progress"]?.int, 2)
    }

    func testNoProgressWithoutAToken() async throws {
        try Data().write(to: folder.appending(path: "Dockerfile"))
        let server = try server(level: .everything, progressInterval: .milliseconds(1))
        let sent = Lines()
        let request: JSON = ["jsonrpc": "2.0", "id": 9, "method": "tools/call",
                             "params": buildCall(["context": .string(folder.path), "tag": "app:dev"])]
        _ = await server.handle(request.line(), notify: sent.append)
        XCTAssertTrue(sent.all.isEmpty)
    }

    func testServeAnswersWhileABuildRunsAndStopsItWhenTheClientGoes() async throws {
        let (engine, call) = try heldBuild()
        let server = try server(level: .everything, engine: engine)
        let input = Pipe(), output = Pipe()
        let serving = Task { await server.serve(input: input.fileHandleForReading, output: output.fileHandleForWriting) }
        let build: JSON = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": call]
        input.fileHandleForWriting.write(Data((build.line() + "\n").utf8))
        try await until { !engine.built.isEmpty }
        let ping: JSON = ["jsonrpc": "2.0", "id": 2, "method": "ping"]
        input.fileHandleForWriting.write(Data((ping.line() + "\n").utf8))
        let answer = await Task.detached { output.fileHandleForReading.availableData }.value
        XCTAssertEqual(JSON.parse(String(decoding: answer, as: UTF8.self).trimmingCharacters(in: .newlines))?["id"]?.int, 2)
        input.fileHandleForWriting.closeFile()
        await serving.value
        XCTAssertTrue(engine.buildEnded)
    }

    func testDeletingAsksFirst() async throws {
        let engine = MockEngine()
        engine.containers = .success([container("web", "running")])
        let denied = try server(level: .everything, approver: Deny(), engine: engine)
        let reply = await send(denied, "tools/call", ["name": "delete_container", "arguments": ["name": "web"]])
        XCTAssertEqual(reply["result"]?["isError"]?.bool, true)
        XCTAssertTrue(engine.deleted.isEmpty)
        let noAsk = try server(level: .everything, ask: false, approver: Deny(), engine: engine)
        _ = await send(noAsk, "tools/call", ["name": "delete_container", "arguments": ["name": "web"]])
        XCTAssertEqual(engine.deleted, ["web"], "with asking off, deleting goes ahead")
    }

    /// The person is asked whether to delete, not told it was deleted.
    func testApprovalAsksInTheImperative() async throws {
        let recorder = Recorder()
        let engine = MockEngine()
        engine.containers = .success([container("web", "running")])
        let asking = try server(level: .everything, approver: recorder, engine: engine)
        _ = await send(asking, "tools/call", ["name": "delete_container", "arguments": ["name": "web"]])
        XCTAssertEqual(recorder.asked, ["delete container web"])
    }

    /// Nobody is asked to allow deleting something that isn't there.
    func testDeletingWhatIsntThereFailsWithoutAsking() async throws {
        let recorder = Recorder()
        let asking = try server(level: .everything, approver: recorder, engine: MockEngine())
        for (tool, key, value) in [("delete_container", "name", "ghost"), ("delete_image", "image", "ghost:1"),
                                   ("delete_volume", "name", "ghost")] {
            let reply = await send(asking, "tools/call", ["name": .string(tool), "arguments": [key: .string(value)]])
            XCTAssertEqual(reply["result"]?["isError"]?.bool, true, tool)
            XCTAssertTrue(reply["result"]?["content"]?.array?.first?["text"]?.string?.hasPrefix("No ") == true, tool)
        }
        XCTAssertTrue(recorder.asked.isEmpty)
    }

    func testListContainersText() async throws {
        let engine = MockEngine()
        engine.containers = .success([container("web", "running"), container("db", "stopped")])
        let reply = await send(try server(level: .lookOnly, engine: engine), "tools/call", ["name": "list_containers"])
        let text = reply["result"]?["content"]?.array?.first?["text"]?.string ?? ""
        XCTAssertTrue(text.contains("web  running  alpine"))
        XCTAssertTrue(text.contains("db  stopped"))
    }

    func testUnknownMethod() async throws {
        let reply = await send(try server(level: .lookOnly), "resources/list")
        XCTAssertEqual(reply["error"]?["code"]?.int, -32601)
    }
}

final class AssistantClientTests: XCTestCase {
    var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    func testJSONClientKeepsOtherServers() throws {
        let cursor = AssistantClient.all.first { $0.id == "cursor" }!
        let file = cursor.configURL(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"mcpServers":{"other":{"command":"x"}},"theme":"dark"}"#.write(to: file, atomically: true, encoding: .utf8)
        try cursor.connect(command: "/Applications/C.app/Contents/MacOS/IrekoboxMCP", key: "k1", home: home)
        XCTAssertEqual(cursor.connectedKey(home: home), "k1")
        let root = JSON.parse(try String(contentsOf: file, encoding: .utf8))
        XCTAssertEqual(root?["theme"]?.string, "dark")
        XCTAssertEqual(root?["mcpServers"]?["other"]?["command"]?.string, "x")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.appendingPathExtension("backup").path))
        try cursor.disconnect(home: home)
        XCTAssertNil(cursor.connectedKey(home: home))
        XCTAssertNotNil(JSON.parse(try String(contentsOf: file, encoding: .utf8))?["mcpServers"]?["other"])
    }

    func testCodexTOML() throws {
        let codex = AssistantClient.all.first { $0.id == "codex" }!
        let file = codex.configURL(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "model = \"o4\"\n\n[mcp_servers.other]\ncommand = \"x\"\n".write(to: file, atomically: true, encoding: .utf8)
        try codex.connect(command: "/path/IrekoboxMCP", key: "k2", home: home)
        XCTAssertEqual(codex.connectedKey(home: home), "k2")
        try codex.connect(command: "/path/IrekoboxMCP", key: "k3", home: home)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "[mcp_servers.irekobox]").count, 2, "replaced, not added twice")
        XCTAssertEqual(codex.connectedKey(home: home), "k3")
        XCTAssertTrue(text.contains("[mcp_servers.other]"))
        try codex.disconnect(home: home)
        XCTAssertNil(codex.connectedKey(home: home))
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("model = \"o4\""))
    }

    func testJSONWithCommentsIsLeftAlone() throws {
        let windsurf = AssistantClient.all.first { $0.id == "windsurf" }!
        let file = windsurf.configURL(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// mine\n{}".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try windsurf.connect(command: "/c", key: "k", home: home))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "// mine\n{}")
    }
}
