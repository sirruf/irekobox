import Foundation

/// The `irekobox` Docker context: lets `docker --context irekobox …`
/// (or `docker context use irekobox`) reach our socket. Created and
/// removed only when the user asks; it writes to ~/.docker.
///
/// A builder of the same name comes with it. In a context, `docker build`
/// always uses the builder named after the context, and the one buildx makes
/// up by itself keeps results in its cache: the build succeeds and no image
/// appears unless `--load` is given. Ours loads by default.
enum DockerContext {
    static let name = "irekobox"

    static func createArguments(socketPath: String) -> [String] {
        ["context", "create", name,
         "--description", "Apple container via Irekobox",
         "--docker", "host=unix://\(socketPath)"]
    }

    static func builderArguments(socketPath: String) -> [String] {
        ["buildx", "create", "--name", name, "--driver", "docker-container",
         "--driver-opt", "default-load=true", "unix://\(socketPath)"]
    }

    private static func dockerFolder(_ environment: [String: String]) -> URL {
        if let path = environment["DOCKER_CONFIG"], !path.isEmpty { return URL(filePath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".docker")
    }

    /// Where buildx keeps its builders.
    static func buildxFolder(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["BUILDX_CONFIG"], !path.isEmpty { return URL(filePath: path) }
        return dockerFolder(environment).appending(path: "buildx")
    }

    /// A Docker config that shows no contexts but still finds the buildx
    /// plugin, wherever the real one says it is.
    static func pluginOnlyConfig(from config: Data?, dockerFolder: URL) throws -> Data {
        let settings = config.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let directories = settings?["cliPluginsExtraDirs"] as? [String] ?? []
        return try JSONSerialization.data(withJSONObject: [
            "cliPluginsExtraDirs": directories + [dockerFolder.appending(path: "cli-plugins").path],
        ])
    }

    /// Creates the builder if it isn't there. buildx refuses a name a context
    /// already has, but only while it can see that context, so this runs
    /// against an empty Docker config and the real builder store.
    static func ensureBuilder(socketPath: String) async throws {
        guard let docker = DockerEnvironment.dockerPath() else { return }
        let environment = ProcessInfo.processInfo.environment
        let store = buildxFolder(environment)
        guard !FileManager.default.fileExists(atPath: store.appending(path: "instances/\(name)").path) else { return }
        let realConfig = dockerFolder(environment)
        let scratch = FileManager.default.temporaryDirectory.appending(path: "irekobox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try pluginOnlyConfig(from: try? Data(contentsOf: realConfig.appending(path: "config.json")),
                             dockerFolder: realConfig)
            .write(to: scratch.appending(path: "config.json"))
        try await ProcessRunner.run(executable: docker, builderArguments(socketPath: socketPath),
                                    environment: ["DOCKER_CONFIG": scratch.path, "BUILDX_CONFIG": store.path])
    }

    /// Whether the context exists (nil when there's no docker CLI).
    static func exists() async -> Bool? {
        guard let docker = DockerEnvironment.dockerPath() else { return nil }
        do {
            _ = try await ProcessRunner.run(executable: docker, ["context", "inspect", name])
            return true
        } catch {
            return false
        }
    }

    static func create(socketPath: String) async throws {
        guard let docker = DockerEnvironment.dockerPath() else { throw ProcessRunner.RunError.notExecutable("docker") }
        try await ProcessRunner.run(executable: docker, createArguments(socketPath: socketPath))
        // Without buildx the classic builder still loads what it builds.
        try? await ensureBuilder(socketPath: socketPath)
    }

    static func remove() async throws {
        guard let docker = DockerEnvironment.dockerPath() else { throw ProcessRunner.RunError.notExecutable("docker") }
        try? await ProcessRunner.run(executable: docker, ["buildx", "rm", name])
        try await ProcessRunner.run(executable: docker, ["context", "rm", name])
    }
}
