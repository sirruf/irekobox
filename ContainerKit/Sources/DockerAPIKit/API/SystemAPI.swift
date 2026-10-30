import Foundation
import ContainerKit

/// What the Docker API needs from the engine. Narrow on purpose: handlers are
/// tested against a stub, and the real thing is any `ContainerEngine`.
public protocol DockerBackend: Sendable {
    func systemStatus() async throws -> SystemStatus?
    func systemProperties() async throws -> String
    func listContainers(all: Bool) async throws -> [Container]
    func listImages() async throws -> [ContainerImage]
    /// References and digests only (see `ContainerEngine.listImageReferences`).
    func listImageReferences() async throws -> [ContainerImage]
    func startContainer(_ id: String) async throws
    func stopContainer(_ id: String, timeout: Int32?, signal: String?) async throws
    func killContainer(_ id: String, signal: String?) async throws
    func deleteContainer(_ id: String, force: Bool) async throws
    func waitContainer(_ id: String) async throws -> ContainerExit
    func createContainer(_ arguments: [String]) async throws
    func createVolume(_ name: String) async throws
    func deleteVolume(_ name: String) async throws
    /// `--progress plain` lines (see ``PullProgress``).
    func pullImage(_ reference: String, platform: String?) -> AsyncThrowingStream<String, Error>
    /// Output lines from the start; with `follow`, then new ones as they come.
    func containerLogs(_ id: String, follow: Bool) -> AsyncThrowingStream<String, Error>
    func containerStats(_ id: String) async throws -> ContainerStats
    func bootstrapContainer(_ id: String, stdio: ProcessStdio) async throws
    func createProcess(_ container: String, process: String, spec: ProcessSpec, stdio: ProcessStdio) async throws
    func startProcess(_ container: String, process: String) async throws
    func resizeProcess(_ container: String, process: String, width: Int, height: Int) async throws
    func waitProcess(_ container: String, process: String) async throws -> ContainerExit
    /// Run a command in a running container; its stdout.
    func execute(_ id: String, command: [String]) async throws -> Data
    func copy(from source: String, to destination: String) async throws
    func exportContainer(_ id: String, to path: String) async throws
    func startServices() async throws
    func deleteImage(_ reference: String, force: Bool) async throws
    func pruneImages(all: Bool) async throws
    func inspectImage(_ reference: String) async throws -> ImageDetails
    func tagImage(_ source: String, as target: String) async throws
    func saveImages(_ references: [String], platform: String?, to path: String) async throws
    func loadImages(from path: String) async throws -> String
    func pushImage(_ reference: String) -> AsyncThrowingStream<String, Error>
    func buildImage(_ options: BuildOptions) -> AsyncThrowingStream<String, Error>
    func listVolumes() async throws -> [Volume]
    func createVolume(_ name: String, labels: [String: String], size: String?) async throws
    func volumeDiskUsage(_ name: String) async throws -> Int64
    func listNetworks() async throws -> [Network]
    func createNetwork(_ spec: NetworkSpec) async throws
    func deleteNetwork(_ name: String) async throws
}

/// Test stubs needn't implement what their tests don't reach.
extension DockerBackend {
    public func listImageReferences() async throws -> [ContainerImage] { try await listImages() }
    public func listVolumes() async throws -> [Volume] { throw DockerAPIError(501, "volumes not available") }
    public func createVolume(_ name: String, labels: [String: String], size: String?) async throws {
        throw DockerAPIError(501, "volumes not available")
    }
    public func volumeDiskUsage(_ name: String) async throws -> Int64 { 0 }
    public func listNetworks() async throws -> [Network] { throw DockerAPIError(501, "networks not available") }
    public func createNetwork(_ spec: NetworkSpec) async throws { throw DockerAPIError(501, "networks not available") }
    public func deleteNetwork(_ name: String) async throws { throw DockerAPIError(501, "networks not available") }
}

/// Adapts a `ContainerEngine` to `DockerBackend`.
public struct EngineBackend: DockerBackend {
    let engine: any ContainerEngine
    private let images = ImageListing()
    public init(engine: any ContainerEngine) { self.engine = engine }

    public func systemStatus() async throws -> SystemStatus? { try await engine.systemStatus() }
    public func systemProperties() async throws -> String { try await engine.systemProperties() }
    public func listContainers(all: Bool) async throws -> [Container] { try await engine.listContainers(all: all) }
    public func listImages() async throws -> [ContainerImage] {
        try await images.list { [engine] in try await engine.listImages() }
    }
    public func listImageReferences() async throws -> [ContainerImage] { try await engine.listImageReferences() }
    public func startContainer(_ id: String) async throws { try await engine.startContainer(id) }
    public func stopContainer(_ id: String, timeout: Int32?, signal: String?) async throws {
        try await engine.stopContainer(id, timeout: timeout, signal: signal)
    }
    public func killContainer(_ id: String, signal: String?) async throws {
        try await engine.killContainer(id, signal: signal)
    }
    public func deleteContainer(_ id: String, force: Bool) async throws {
        try await engine.deleteContainer(id, force: force)
    }
    public func waitContainer(_ id: String) async throws -> ContainerExit { try await engine.waitContainer(id) }
    public func createContainer(_ arguments: [String]) async throws { try await engine.createContainer(arguments) }
    public func createVolume(_ name: String) async throws { try await engine.createVolume(name) }
    public func deleteVolume(_ name: String) async throws { try await engine.deleteVolume(name) }
    public func pullImage(_ reference: String, platform: String?) -> AsyncThrowingStream<String, Error> {
        images.changing(engine.pullImageWithProgress(reference, platform: platform))
    }
    public func containerLogs(_ id: String, follow: Bool) -> AsyncThrowingStream<String, Error> {
        engine.containerLogs(id, follow: follow)
    }
    public func containerStats(_ id: String) async throws -> ContainerStats { try await engine.containerStats(id) }
    public func bootstrapContainer(_ id: String, stdio: ProcessStdio) async throws {
        try await engine.bootstrapContainer(id, stdio: stdio)
    }
    public func createProcess(_ container: String, process: String, spec: ProcessSpec, stdio: ProcessStdio) async throws {
        try await engine.createProcess(container, process: process, spec: spec, stdio: stdio)
    }
    public func startProcess(_ container: String, process: String) async throws {
        try await engine.startProcess(container, process: process)
    }
    public func resizeProcess(_ container: String, process: String, width: Int, height: Int) async throws {
        try await engine.resizeProcess(container, process: process, width: width, height: height)
    }
    public func waitProcess(_ container: String, process: String) async throws -> ContainerExit {
        try await engine.waitProcess(container, process: process)
    }
    public func execute(_ id: String, command: [String]) async throws -> Data {
        try await engine.execute(id, command: command)
    }
    public func copy(from source: String, to destination: String) async throws {
        try await engine.copy(from: source, to: destination)
    }
    public func exportContainer(_ id: String, to path: String) async throws {
        try await engine.exportContainer(id, to: path)
    }
    public func startServices() async throws { try await engine.startServices() }
    public func deleteImage(_ reference: String, force: Bool) async throws {
        try await images.changing { try await engine.deleteImage(reference, force: force) }
    }
    public func pruneImages(all: Bool) async throws {
        try await images.changing { try await engine.pruneImages(all: all) }
    }
    public func inspectImage(_ reference: String) async throws -> ImageDetails { try await engine.inspectImage(reference) }
    public func tagImage(_ source: String, as target: String) async throws {
        try await images.changing { try await engine.tagImage(source, as: target) }
    }
    public func saveImages(_ references: [String], platform: String?, to path: String) async throws {
        try await engine.saveImages(references, platform: platform, to: path)
    }
    public func loadImages(from path: String) async throws -> String {
        try await images.changing { try await engine.loadImages(from: path) }
    }
    public func pushImage(_ reference: String) -> AsyncThrowingStream<String, Error> { engine.pushImage(reference) }
    public func buildImage(_ options: BuildOptions) -> AsyncThrowingStream<String, Error> {
        images.changing(engine.buildImage(options))
    }
    public func listVolumes() async throws -> [Volume] { try await engine.listVolumes() }
    public func createVolume(_ name: String, labels: [String: String], size: String?) async throws {
        try await engine.createVolume(name, labels: labels, size: size, options: [:])
    }
    public func volumeDiskUsage(_ name: String) async throws -> Int64 { try await engine.volumeDiskUsage(name) }
    public func listNetworks() async throws -> [Network] { try await engine.listNetworks() }
    public func createNetwork(_ spec: NetworkSpec) async throws { try await engine.createNetwork(spec) }
    public func deleteNetwork(_ name: String) async throws { try await engine.deleteNetwork(name) }
}

/// Listing images is slow (`container image ls` reads every image's size: a
/// quarter of a second with some fifty images), and Compose asks about every
/// service's image at once. Concurrent callers share one listing, unless an
/// image changed through this backend since it began.
final class ImageListing: Sendable {
    private let state = State()

    private actor State {
        var generation = 0
        var running: (generation: Int, task: Task<[ContainerImage], Error>)?

        func task(_ fetch: @escaping @Sendable () async throws -> [ContainerImage]) -> Task<[ContainerImage], Error> {
            if let running, running.generation == generation { return running.task }
            let task = Task { try await fetch() }
            running = (generation, task)
            return task
        }

        func finished(_ task: Task<[ContainerImage], Error>) {
            if running?.task == task { running = nil }
        }

        func changed() { generation += 1 }
    }

    func list(_ fetch: @escaping @Sendable () async throws -> [ContainerImage]) async throws -> [ContainerImage] {
        let task = await state.task(fetch)
        defer { Task { await state.finished(task) } }
        return try await task.value
    }

    /// Run a change to the images; listings begun before it ends aren't shared.
    func changing<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        await state.changed()
        do {
            let result = try await body()
            await state.changed()
            return result
        } catch {
            await state.changed()
            throw error
        }
    }

    func changing(_ stream: AsyncThrowingStream<String, Error>) -> AsyncThrowingStream<String, Error> {
        let state = state
        return AsyncThrowingStream { continuation in
            let task = Task {
                await state.changed()
                do {
                    for try await line in stream { continuation.yield(line) }
                    await state.changed()
                    continuation.finish()
                } catch {
                    await state.changed()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Facts about this host and app that `version`/`info` report.
public struct DockerHostInfo: Sendable {
    public var appVersion: String
    public var hostName: String
    public var cpus: Int
    public var memoryBytes: UInt64
    public var macOSVersion: String

    public init(appVersion: String, hostName: String = ProcessInfo.processInfo.hostName,
                cpus: Int = ProcessInfo.processInfo.activeProcessorCount,
                memoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
                macOSVersion: String = ProcessInfo.processInfo.operatingSystemVersionString) {
        self.appVersion = appVersion
        self.hostName = hostName
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.macOSVersion = macOSVersion
    }
}

/// `/_ping`, `/version`, `/info`.
public enum SystemAPI {
    /// The Docker Engine release line whose API we implement. Some tools gate
    /// features on `Version` as if it were Docker's; the real components are
    /// listed under `Components`.
    public static let engineCompatibleVersion = "29.0.0"

    public static func register(on router: inout DockerRouter, backend: DockerBackend, host: DockerHostInfo) {
        router.add("GET", "/_ping") { _ in ping() }
        router.add("HEAD", "/_ping") { _ in ping() }
        router.add("GET", "/version") { _ in await version(backend: backend, host: host) }
        router.add("GET", "/info") { _ in await info(backend: backend, host: host) }

        // Swarm and managed plugins don't exist here; answer like a standalone
        // Docker Engine so tools treat this as a non-swarm host.
        for prefix in ["/swarm", "/nodes", "/services", "/tasks", "/secrets", "/configs"] {
            router.addPrefix(prefix) { _ in
                .error(503, "This node is not a swarm manager. Swarm mode is not supported by Irekobox.")
            }
        }
        router.add("GET", "/plugins") { _ in .json([String]()) }
        router.addPrefix("/plugins") { _ in .error(501, "Managed plugins are not supported by Irekobox.") }
    }

    static func ping() -> HTTPResponse {
        HTTPResponse(status: 200, headers: [("Content-Type", "text/plain; charset=utf-8"),
                                            ("Cache-Control", "no-cache, no-store, must-revalidate"),
                                            ("Pragma", "no-cache"),
                                            ("Builder-Version", "1")],
                     body: .data(Data("OK".utf8)))
    }

    // MARK: - /version

    struct Version: Encodable {
        struct Platform: Encodable { let Name: String }
        struct Component: Encodable {
            let Name: String
            let Version: String
            let Details: [String: String]?
        }
        let Platform: Platform
        let Components: [Component]
        let Version: String
        let ApiVersion: String
        let MinAPIVersion: String
        let GitCommit: String
        let GoVersion: String
        let Os: String
        let Arch: String
        let KernelVersion: String
        let BuildTime: String
    }

    static func version(backend: DockerBackend, host: DockerHostInfo) async -> HTTPResponse {
        let status = try? await backend.systemStatus()
        let kernel = await kernelVersion(backend)
        let containerVersion = status?.apiServerVersion ?? "unknown"
        return .json(Version(
            Platform: .init(Name: "Irekobox \(host.appVersion)"),
            Components: [
                .init(Name: "Engine", Version: engineCompatibleVersion,
                      Details: ["ApiVersion": DockerAPIVersion.current.description,
                                "MinAPIVersion": DockerAPIVersion.minimum.description,
                                "Os": "linux", "Arch": "arm64",
                                "KernelVersion": kernel,
                                "GitCommit": status?.server?.commit.map { String($0.prefix(7)) } ?? "",
                                "GoVersion": "n/a (Swift)",
                                "Experimental": "false",
                                "BuildTime": ""]),
                .init(Name: "Irekobox", Version: host.appVersion, Details: nil),
                .init(Name: "container", Version: containerVersion,
                      Details: ["GitCommit": status?.server?.commit ?? ""]),
            ],
            Version: engineCompatibleVersion,
            ApiVersion: DockerAPIVersion.current.description,
            MinAPIVersion: DockerAPIVersion.minimum.description,
            GitCommit: status?.server?.commit.map { String($0.prefix(7)) } ?? "",
            GoVersion: "n/a (Swift)",
            Os: "linux",
            Arch: "arm64",
            KernelVersion: kernel,
            BuildTime: ""))
    }

    // MARK: - /info

    struct Info: Encodable {
        struct Swarm: Encodable {
            let NodeID = ""
            let NodeAddr = ""
            let LocalNodeState = "inactive"
            let ControlAvailable = false
            let Error = ""
            let RemoteManagers: [String]? = nil
        }
        struct Plugins: Encodable {
            let Volume = ["local"]
            let Network = ["bridge"]
            let Authorization: [String]? = nil
            let Log = ["json-file"]
        }
        let ID: String
        let Containers: Int
        let ContainersRunning: Int
        let ContainersPaused = 0
        let ContainersStopped: Int
        let Images: Int
        let Driver = "container"
        let DriverStatus: [[String]] = []
        let DockerRootDir: String
        let Plugins = Plugins()
        let MemoryLimit = true
        let SwapLimit = false
        let CpuCfsPeriod = false
        let CpuCfsQuota = false
        let CPUShares = false
        let CPUSet = false
        let PidsLimit = false
        let OomKillDisable = false
        let IPv4Forwarding = true
        let Debug = false
        let NFd = 0
        let NGoroutines = 0
        let SystemTime: String
        let LoggingDriver = "json-file"
        let CgroupDriver = "none"
        let CgroupVersion = "2"
        let NEventsListener = 0
        let KernelVersion: String
        let OperatingSystem: String
        let OSVersion: String
        let OSType = "linux"
        let Architecture = "aarch64"
        let NCPU: Int
        let MemTotal: UInt64
        let IndexServerAddress = "https://index.docker.io/v1/"
        let HttpProxy = ""
        let HttpsProxy = ""
        let NoProxy = ""
        let Name: String
        let Labels: [String] = []
        let ExperimentalBuild = false
        let ServerVersion: String
        let DefaultRuntime = "container"
        let Swarm = Swarm()
        let LiveRestoreEnabled = false
        let Isolation = ""
        let SecurityOptions: [String] = []
        let Warnings: [String]
    }

    static func info(backend: DockerBackend, host: DockerHostInfo) async -> HTTPResponse {
        let status: SystemStatus?
        do {
            status = try await backend.systemStatus()
        } catch {
            return .error(500, "container services: \(error.localizedDescription)")
        }
        guard let status, status.isRunning else {
            return .error(500, "container services are not running. Start them in Irekobox or with `container system start`.")
        }
        var warnings: [String] = []
        let containers: [Container]
        do {
            containers = try await backend.listContainers(all: true).filter { !$0.isSystem }
        } catch {
            containers = []
            warnings.append("Containers unavailable: \(error.localizedDescription)")
        }
        let images = (try? await backend.listImages().filter { !$0.isSystem }) ?? []
        let running = containers.filter { $0.state.isRunning }.count

        return .json(Info(
            ID: "irekobox-\(host.hostName)",
            Containers: containers.count,
            ContainersRunning: running,
            ContainersStopped: containers.count - running,
            Images: images.count,
            DockerRootDir: status.appRoot ?? "",
            SystemTime: DockerTime.string(Date()),
            KernelVersion: await kernelVersion(backend),
            OperatingSystem: "Apple container \(status.apiServerVersion ?? "") (via Irekobox)",
            OSVersion: host.macOSVersion,
            NCPU: status.hostCPUs ?? host.cpus,
            MemTotal: host.memoryBytes,
            Name: host.hostName,
            ServerVersion: engineCompatibleVersion,
            Warnings: warnings))
    }

    /// "vmlinux-6.18.35-197-debug" from `[kernel] binaryPath` → "6.18.35-197-debug".
    static func kernelVersion(_ backend: DockerBackend) async -> String {
        guard let properties = try? await backend.systemProperties(),
              let line = properties.split(separator: "\n").first(where: { $0.hasPrefix("binaryPath") }),
              let match = line.firstMatch(of: /vmlinux-([^"\/]+)/) else { return "" }
        return String(match.1)
    }
}
