import Foundation

/// The `irekobox` Docker context: lets `docker --context irekobox …`
/// (or `docker context use irekobox`) reach our socket. Created and
/// removed only when the user asks; it writes to ~/.docker.
enum DockerContext {
    static let name = "irekobox"

    static func createArguments(socketPath: String) -> [String] {
        ["context", "create", name,
         "--description", "Apple container via Irekobox",
         "--docker", "host=unix://\(socketPath)"]
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
    }

    static func remove() async throws {
        guard let docker = DockerEnvironment.dockerPath() else { throw ProcessRunner.RunError.notExecutable("docker") }
        try await ProcessRunner.run(executable: docker, ["context", "rm", name])
    }
}
