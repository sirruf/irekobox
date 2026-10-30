import Foundation

/// ``ContainerEngine`` backed by the `container` CLI, composed from the
/// per-domain repositories.
public struct CLIEngine: ContainerEngine {
    /// Raw CLI access for flows that run arbitrary `container` argv
    /// (docker-run translation, migration, compose).
    public let cli: any ContainerCommanding

    private let containers: ContainerRepository
    private let system: SystemRepository
    private let images: ImageRepository
    private let builds: BuildRepository
    private let volumes: VolumeRepository
    private let networks: NetworkRepository
    private let registries: RegistryRepository
    private let stream: CLIStream

    public init(cli: any ContainerCommanding, stream: CLIStream) {
        self.cli = cli
        self.stream = stream
        containers = ContainerRepository(cli: cli)
        system = SystemRepository(cli: cli)
        images = ImageRepository(cli: cli)
        builds = BuildRepository(stream: stream)
        volumes = VolumeRepository(cli: cli)
        networks = NetworkRepository(cli: cli)
        registries = RegistryRepository(cli: cli)
    }

    /// Engine for the binary at `binaryPath`.
    public init(binaryPath: String = ContainerCLI.defaultBinaryPath) {
        self.init(cli: ContainerCLI(binaryPath: binaryPath), stream: CLIStream(binaryPath: binaryPath))
    }

    // MARK: System

    public func systemStatus() async throws -> SystemStatus? { try await system.status() }
    public func startServices() async throws { try await system.startServices() }
    public func stopServices() async throws { try await system.stopServices() }
    public func supportsVolumeSync() async -> Bool {
        guard let help = try? await cli.data(["run", "--help"]) else { return false }
        return String(decoding: help, as: UTF8.self).contains("sync=full|fsync|nosync")
    }
    public func systemProperties() async throws -> String {
        String(decoding: try await cli.data(["system", "property", "list"]), as: UTF8.self)
    }
    public func systemLogs(last: String) async throws -> String {
        String(decoding: try await cli.data(["system", "logs", "--last", last]), as: UTF8.self)
    }
    public func diskUsage() async throws -> SystemDiskUsage { try await system.diskUsage() }
    public func builderStatus() async throws -> BuilderStatus { try await system.builderStatus() }

    // MARK: Containers

    public func listContainers(all: Bool) async throws -> [Container] { try await containers.list(all: all) }
    public func inspectContainer(_ id: String) async throws -> Container { try await containers.inspect(id) }
    public func startContainer(_ id: String) async throws { try await containers.start(id) }
    public func stopContainer(_ id: String, timeout: Int32?, signal: String?) async throws {
        try await containers.stop(id, timeout: timeout, signal: signal)
    }
    // The CLI can't hand over file descriptors; these need the XPC engine.
    public func bootstrapContainer(_ id: String, stdio: ProcessStdio) async throws { throw Self.needsXPC }
    public func createProcess(_ container: String, process: String, spec: ProcessSpec, stdio: ProcessStdio) async throws {
        throw Self.needsXPC
    }
    public func startProcess(_ container: String, process: String) async throws { throw Self.needsXPC }
    public func resizeProcess(_ container: String, process: String, width: Int, height: Int) async throws { throw Self.needsXPC }
    public func waitProcess(_ container: String, process: String) async throws -> ContainerExit { throw Self.needsXPC }
    static let needsXPC = EngineError.serviceError(code: "unsupported", message: "this needs the XPC engine")

    public func waitContainer(_ id: String) async throws -> ContainerExit {
        // The CLI has no `wait`; exit codes come from the apiserver (XPCEngine).
        throw EngineError.serviceError(code: "unsupported", message: "waiting for a container needs the XPC engine")
    }
    public func killContainer(_ id: String, signal: String?) async throws {
        try await containers.kill(id, signal: signal)
    }
    public func deleteContainer(_ id: String, force: Bool) async throws {
        try await containers.delete(id, force: force)
    }
    public func pruneContainers() async throws { try await containers.prune() }
    public func runContainer(_ arguments: [String]) async throws { try await cli.run(["run"] + arguments) }
    public func createContainer(_ arguments: [String]) async throws { try await cli.run(["create"] + arguments) }
    public func recreateContainer(_ container: Container, edits: ContainerEdits) async throws {
        try await containers.recreate(container, edits: edits)
    }
    public func containerStats(_ id: String) async throws -> ContainerStats { try await containers.stats(id) }
    public func execute(_ id: String, command: [String]) async throws -> Data {
        try await cli.data(["exec", id] + command)
    }
    public func inspectImage(_ reference: String) async throws -> ImageDetails {
        let list = try await cli.decode([ImageDetails].self, ["image", "inspect", reference])
        guard let first = list.first else { throw EngineError.notFound(reference) }
        return first
    }
    public func tagImage(_ source: String, as target: String) async throws {
        try await cli.run(["image", "tag", source, target])
    }
    public func saveImages(_ references: [String], platform: String?, to path: String) async throws {
        var arguments = ["image", "save", "--output", path]
        if let platform { arguments += ["--platform", platform] }
        try await cli.run(arguments + references)
    }
    public func loadImages(from path: String) async throws -> String {
        String(decoding: try await cli.data(["image", "load", "--input", path]), as: UTF8.self)
    }

    public func copy(from source: String, to destination: String) async throws {
        try await cli.run(["copy", source, destination])
    }
    public func exportContainer(_ id: String, to path: String) async throws {
        try await cli.run(["export", "--output", path, id])
    }
    public func containerLogs(_ id: String, follow: Bool) -> AsyncThrowingStream<String, Error> {
        stream.logs(id, follow: follow)
    }

    // MARK: Images

    public func listImages() async throws -> [ContainerImage] { try await images.list() }
    public func pullImage(_ reference: String) async throws { try await images.pull(reference) }
    public func deleteImage(_ reference: String, force: Bool) async throws {
        try await images.delete(reference, force: force)
    }
    public func pruneImages(all: Bool) async throws { try await images.prune(all: all) }
    public func pullImageWithProgress(_ reference: String, platform: String?) -> AsyncThrowingStream<String, Error> {
        var arguments = ["image", "pull", "--progress", "plain"]
        if let platform { arguments += ["--platform", platform] }
        return stream.lines(arguments + [reference], mergeStderr: true)
    }
    public func buildImage(_ options: BuildOptions) -> AsyncThrowingStream<String, Error> { builds.build(options) }
    public func pushImage(_ reference: String) -> AsyncThrowingStream<String, Error> { builds.push(reference) }

    // MARK: Volumes

    public func listVolumes() async throws -> [Volume] { try await volumes.list() }
    public func createVolume(_ name: String) async throws { try await volumes.create(name) }
    public func createVolume(_ name: String, labels: [String: String], size: String?, options: [String: String]) async throws {
        try await volumes.create(name, labels: labels, size: size, options: options)
    }

    /// Allocated blocks of the volume's image file (the CLI has no command for this).
    public func volumeDiskUsage(_ name: String) async throws -> Int64 {
        guard let source = try await volumes.list().first(where: { $0.name == name })?.source else {
            throw EngineError.notFound("Volume \(name) not found.")
        }
        let values = try URL(fileURLWithPath: source).resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return Int64(values.totalFileAllocatedSize ?? 0)
    }
    public func deleteVolume(_ name: String) async throws { try await volumes.delete(name) }
    public func pruneVolumes() async throws { try await volumes.prune() }

    // MARK: Networks

    public func listNetworks() async throws -> [Network] { try await networks.list() }
    public func createNetwork(_ name: String, subnet: String?) async throws {
        try await networks.create(name, subnet: subnet)
    }
    public func createNetwork(_ spec: NetworkSpec) async throws { try await networks.create(spec) }
    public func deleteNetwork(_ name: String) async throws { try await networks.delete(name) }
    public func pruneNetworks() async throws { try await networks.prune() }

    // MARK: Registries

    public func listRegistryLogins() async throws -> [RegistryLogin] { try await registries.list() }
    public func registryLogin(server: String, username: String, password: String,
                              scheme: RegistryScheme) async throws {
        try await registries.login(server: server, username: username, password: password, scheme: scheme)
    }
    public func registryLogout(server: String) async throws { try await registries.logout(server: server) }
}
