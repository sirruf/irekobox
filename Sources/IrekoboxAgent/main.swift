import Foundation
import ContainerKit
import EngineCore
import DockerAPIKit

// Background agent: hosts the engine store so state stays current with the
// app closed, records container exits, and serves the Docker Engine API on
// ~/.irekobox/docker.sock when enabled in Settings. launchd starts it
// from the app bundle via SMAppService and keeps it alive.

/// Engine for the Docker side; replaced when the `container` path changes.
final class DockerEngineBox: DockerBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var path = ContainerCLI.defaultBinaryPath
    private var backend = EngineBackend(engine: DockerEngineBox.engine(ContainerCLI.defaultBinaryPath))

    static func engine(_ path: String) -> any ContainerEngine {
        XPCEngine(fallback: CLIEngine(cli: ContainerCLI(binaryPath: path), stream: CLIStream(binaryPath: path)))
    }

    func use(binaryPath: String) {
        lock.withLock {
            guard binaryPath != path else { return }
            path = binaryPath
            backend = EngineBackend(engine: Self.engine(binaryPath))
        }
    }

    private var current: EngineBackend { lock.withLock { backend } }

    func systemStatus() async throws -> SystemStatus? { try await current.systemStatus() }
    func systemProperties() async throws -> String { try await current.systemProperties() }
    func listContainers(all: Bool) async throws -> [Container] { try await current.listContainers(all: all) }
    func listImages() async throws -> [ContainerImage] { try await current.listImages() }
    func startContainer(_ id: String) async throws { try await current.startContainer(id) }
    func stopContainer(_ id: String, timeout: Int32?, signal: String?) async throws {
        try await current.stopContainer(id, timeout: timeout, signal: signal)
    }
    func killContainer(_ id: String, signal: String?) async throws { try await current.killContainer(id, signal: signal) }
    func deleteContainer(_ id: String, force: Bool) async throws { try await current.deleteContainer(id, force: force) }
    func waitContainer(_ id: String) async throws -> ContainerExit { try await current.waitContainer(id) }
    func createContainer(_ arguments: [String]) async throws { try await current.createContainer(arguments) }
    func createVolume(_ name: String) async throws { try await current.createVolume(name) }
    func deleteVolume(_ name: String) async throws { try await current.deleteVolume(name) }
    func pullImage(_ reference: String, platform: String?) -> AsyncThrowingStream<String, Error> {
        current.pullImage(reference, platform: platform)
    }
    func containerLogs(_ id: String, follow: Bool) -> AsyncThrowingStream<String, Error> {
        current.containerLogs(id, follow: follow)
    }
    func containerStats(_ id: String) async throws -> ContainerStats { try await current.containerStats(id) }
    func bootstrapContainer(_ id: String, stdio: ProcessStdio) async throws {
        try await current.bootstrapContainer(id, stdio: stdio)
    }
    func createProcess(_ container: String, process: String, spec: ProcessSpec, stdio: ProcessStdio) async throws {
        try await current.createProcess(container, process: process, spec: spec, stdio: stdio)
    }
    func startProcess(_ container: String, process: String) async throws {
        try await current.startProcess(container, process: process)
    }
    func resizeProcess(_ container: String, process: String, width: Int, height: Int) async throws {
        try await current.resizeProcess(container, process: process, width: width, height: height)
    }
    func waitProcess(_ container: String, process: String) async throws -> ContainerExit {
        try await current.waitProcess(container, process: process)
    }
    func execute(_ id: String, command: [String]) async throws -> Data { try await current.execute(id, command: command) }
    func copy(from source: String, to destination: String) async throws { try await current.copy(from: source, to: destination) }
    func exportContainer(_ id: String, to path: String) async throws { try await current.exportContainer(id, to: path) }
    func startServices() async throws { try await current.startServices() }
    func deleteImage(_ reference: String, force: Bool) async throws { try await current.deleteImage(reference, force: force) }
    func pruneImages(all: Bool) async throws { try await current.pruneImages(all: all) }
    func inspectImage(_ reference: String) async throws -> ImageDetails { try await current.inspectImage(reference) }
    func tagImage(_ source: String, as target: String) async throws { try await current.tagImage(source, as: target) }
    func saveImages(_ references: [String], platform: String?, to path: String) async throws {
        try await current.saveImages(references, platform: platform, to: path)
    }
    func loadImages(from path: String) async throws -> String { try await current.loadImages(from: path) }
    func pushImage(_ reference: String) -> AsyncThrowingStream<String, Error> { current.pushImage(reference) }
    func buildImage(_ options: BuildOptions) -> AsyncThrowingStream<String, Error> { current.buildImage(options) }
    func listVolumes() async throws -> [Volume] { try await current.listVolumes() }
    func createVolume(_ name: String, labels: [String: String], size: String?) async throws {
        try await current.createVolume(name, labels: labels, size: size)
    }
    func volumeDiskUsage(_ name: String) async throws -> Int64 { try await current.volumeDiskUsage(name) }
    func listNetworks() async throws -> [Network] { try await current.listNetworks() }
    func createNetwork(_ spec: NetworkSpec) async throws { try await current.createNetwork(spec) }
    func deleteNetwork(_ name: String) async throws { try await current.deleteNetwork(name) }
}

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
let engines = DockerEngineBox()
let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appending(path: "Irekobox")
let docker = DockerHost(backend: engines, appVersion: appVersion,
                        socketPath: DockerSocketStatus.defaultPath,
                        exitsFile: support.appending(path: "container-exits.json"),
                        supervisorFile: support.appending(path: "supervisor.json"))

let server = AgentServer()
server.onConfigure = { configuration in
    engines.use(binaryPath: configuration.binaryPath)
    await docker.setEnabled(configuration.dockerSocketEnabled)
}
server.onHandAction = { stopped, names in
    await docker.handAction(stopped: stopped, names: names)
}
server.alerts = { sequence in await docker.alerts(after: sequence) }
server.healthStatuses = { await docker.healthStatuses() }
// At login: start the engine if asked to; the supervisor then brings up
// containers whose restart policy says so.
server.onLaunch = { saved in
    guard let saved, saved.startEngineAtLogin else { return }
    if (try? await engines.systemStatus())??.isRunning != true {
        try? await engines.startServices()
    }
}
server.dockerStatus = {
    let status = await docker.status()
    return DockerSocketStatus(enabled: status.enabled, listening: status.listening,
                              socketPath: status.socketPath, error: status.error)
}
Task { await docker.start() }
server.resume()
dispatchMain()
