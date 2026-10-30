import Foundation

/// Domain service for `container image`.
public struct ImageRepository: Sendable {
    private let cli: any ContainerCommanding

    public init(cli: any ContainerCommanding) {
        self.cli = cli
    }

    public func list() async throws -> [ContainerImage] {
        try await cli.decode([ContainerImage].self, ["image", "ls", "--format", "json"])
    }

    /// `container image pull <reference>`.
    public func pull(_ reference: String) async throws {
        try await cli.run(["image", "pull", reference])
    }

    /// `container image delete [--force] <reference>`.
    public func delete(_ reference: String, force: Bool = false) async throws {
        var arguments = ["image", "delete"]
        if force { arguments.append("--force") }
        arguments.append(reference)
        try await cli.run(arguments)
    }

    /// `container image prune [--all]`.
    public func prune(all: Bool = false) async throws {
        try await cli.run(["image", "prune"] + (all ? ["--all"] : []))
    }
}
