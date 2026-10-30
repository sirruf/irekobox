import Foundation

public typealias BuildOptions = BuildRepository.Options
public typealias RegistryScheme = RegistryRepository.Scheme

/// Everything the app needs from Apple `container`, independent of transport.
///
/// ``CLIEngine`` implements it by running the `container` CLI; an XPC engine
/// talking to `container-apiserver` directly will implement the same contract
/// (falling back to the CLI where XPC has no equivalent). All methods throw
/// ``EngineError``.
public protocol ContainerEngine: Sendable {
    // MARK: System

    /// `nil` when services are not running.
    func systemStatus() async throws -> SystemStatus?
    func startServices() async throws
    func stopServices() async throws
    /// Effective system configuration (`container system property list`, TOML).
    func systemProperties() async throws -> String
    /// Logs of the `container` services for a period such as `10m` or `1h`.
    func systemLogs(last: String) async throws -> String
    func diskUsage() async throws -> SystemDiskUsage
    func builderStatus() async throws -> BuilderStatus

    // MARK: Containers

    func listContainers(all: Bool) async throws -> [Container]
    func inspectContainer(_ id: String) async throws -> Container
    func startContainer(_ id: String) async throws
    /// Stop with a grace period (`nil`: the runtime's default, 5 s) and an
    /// optional first signal instead of SIGTERM.
    func stopContainer(_ id: String, timeout: Int32?, signal: String?) async throws
    /// Block until the container's init process exits; its code and time.
    /// A container that ran before answers at once with its last exit.
    func waitContainer(_ id: String) async throws -> ContainerExit

    // Processes with our own stdio (attach, exec). The init process of a
    // container has the container's ID as its process ID.
    /// Prepare a created container's init process with `stdio`; `startProcess` runs it.
    func bootstrapContainer(_ id: String, stdio: ProcessStdio) async throws
    func createProcess(_ container: String, process: String, spec: ProcessSpec, stdio: ProcessStdio) async throws
    func startProcess(_ container: String, process: String) async throws
    func resizeProcess(_ container: String, process: String, width: Int, height: Int) async throws
    func waitProcess(_ container: String, process: String) async throws -> ContainerExit
    func killContainer(_ id: String, signal: String?) async throws
    func deleteContainer(_ id: String, force: Bool) async throws
    /// Remove all stopped containers.
    func pruneContainers() async throws
    /// `container run <arguments>` (detached); returns once it is started.
    func runContainer(_ arguments: [String]) async throws
    /// `container create <arguments>`: created, not started.
    func createContainer(_ arguments: [String]) async throws
    /// Replace a container with one built from its configuration plus `edits`.
    func recreateContainer(_ container: Container, edits: ContainerEdits) async throws
    func containerStats(_ id: String) async throws -> ContainerStats
    /// Run `command` in a running container and return its standard output.
    func execute(_ id: String, command: [String]) async throws -> Data
    /// `container cp`: either side may be `<container>:<path>` or a local path.
    func copy(from source: String, to destination: String) async throws
    /// `container export`: the container's filesystem as a tar file at `path`.
    func exportContainer(_ id: String, to path: String) async throws
    /// Container output, line by line; ends when the consumer stops iterating.
    func containerLogs(_ id: String, follow: Bool) -> AsyncThrowingStream<String, Error>

    // MARK: Images

    func listImages() async throws -> [ContainerImage]
    func pullImage(_ reference: String) async throws
    /// Pull with `--progress plain` output lines (see ``PullProgress``).
    /// `platform` limits the pull (e.g. `linux/arm64`); `nil` pulls every variant.
    func pullImageWithProgress(_ reference: String, platform: String?) -> AsyncThrowingStream<String, Error>
    func deleteImage(_ reference: String, force: Bool) async throws
    /// Dangling images only, or (`all`) every image no container uses.
    func pruneImages(all: Bool) async throws
    /// Build progress lines (BuildKit `--progress plain`).
    func buildImage(_ options: BuildOptions) -> AsyncThrowingStream<String, Error>
    /// Push progress lines.
    func pushImage(_ reference: String) -> AsyncThrowingStream<String, Error>
    func inspectImage(_ reference: String) async throws -> ImageDetails
    /// A new reference for an existing image.
    func tagImage(_ source: String, as target: String) async throws
    /// OCI archive of `references` at `path`; `platform` picks one variant.
    func saveImages(_ references: [String], platform: String?, to path: String) async throws
    /// Load an OCI archive; the CLI's report (lists what was loaded).
    func loadImages(from path: String) async throws -> String

    // MARK: Volumes

    func listVolumes() async throws -> [Volume]
    /// Space the volume actually uses on disk (its image file is sparse:
    /// `sizeInBytes` is the capacity, not the usage).
    func volumeDiskUsage(_ name: String) async throws -> Int64
    func createVolume(_ name: String) async throws
    func createVolume(_ name: String, labels: [String: String], size: String?, options: [String: String]) async throws
    func deleteVolume(_ name: String) async throws
    func pruneVolumes() async throws

    // MARK: Networks

    func listNetworks() async throws -> [Network]
    func createNetwork(_ name: String, subnet: String?) async throws
    func createNetwork(_ spec: NetworkSpec) async throws
    func deleteNetwork(_ name: String) async throws
    func pruneNetworks() async throws

    // MARK: Registries

    func listRegistryLogins() async throws -> [RegistryLogin]
    func registryLogin(server: String, username: String, password: String, scheme: RegistryScheme) async throws
    func registryLogout(server: String) async throws
}

public extension ContainerEngine {
    func stopContainer(_ id: String) async throws {
        try await stopContainer(id, timeout: nil, signal: nil)
    }
}
