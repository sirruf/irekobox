import Foundation

/// Domain service for `container registry` — logins for image registries.
public struct RegistryRepository: Sendable {
    public enum Scheme: String, Sendable, CaseIterable {
        case auto, https, http
    }

    private let cli: any ContainerCommanding

    public init(cli: any ContainerCommanding) {
        self.cli = cli
    }

    /// `container registry ls --format json`.
    public func list() async throws -> [RegistryLogin] {
        try await cli.decode([RegistryLogin].self, ["registry", "ls", "--format", "json"])
    }

    /// `container registry login <server> -u <user> --password-stdin [--scheme]`.
    /// The password is sent via stdin, never as an argument.
    public func login(server: String, username: String, password: String, scheme: Scheme = .auto) async throws {
        var arguments = ["registry", "login", server, "--username", username, "--password-stdin"]
        if scheme != .auto { arguments += ["--scheme", scheme.rawValue] }
        let secret = Data((password + "\n").utf8)
        try await cli.run(arguments, input: secret)
    }

    /// `container registry logout <server>`.
    public func logout(server: String) async throws {
        try await cli.run(["registry", "logout", server])
    }
}
