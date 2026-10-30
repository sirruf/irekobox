import Foundation

/// Domain service for container lifecycle, built on ``ContainerCLI``.
public struct ContainerRepository: Sendable {
    private let cli: any ContainerCommanding

    public init(cli: any ContainerCommanding) {
        self.cli = cli
    }

    /// `container list [--all] --format json`.
    public func list(all: Bool = true) async throws -> [Container] {
        var arguments = ["list", "--format", "json"]
        if all { arguments.append("--all") }
        return try await cli.decode([Container].self, arguments)
    }

    /// `container inspect <id> --format json` (returns the first match).
    public func inspect(_ id: String) async throws -> Container {
        let containers = try await cli.decode([Container].self, ["inspect", id])
        guard let first = containers.first else {
            throw EngineError.notFound("Container \(id) not found.")
        }
        return first
    }

    public func start(_ id: String) async throws {
        try await cli.run(["start", id])
    }

    public func stop(_ id: String, timeout: Int32? = nil, signal: String? = nil) async throws {
        var arguments = ["stop"]
        if let timeout { arguments += ["--time", "\(timeout)"] }
        if let signal { arguments += ["--signal", signal] }
        arguments.append(id)
        try await cli.run(arguments)
    }

    public func kill(_ id: String, signal: String? = nil) async throws {
        var arguments = ["kill"]
        if let signal { arguments += ["--signal", signal] }
        arguments.append(id)
        try await cli.run(arguments)
    }

    public func delete(_ id: String, force: Bool = false) async throws {
        var arguments = ["delete"]
        if force { arguments.append("--force") }
        arguments.append(id)
        try await cli.run(arguments)
    }

    /// `container prune` — remove all stopped containers.
    public func prune() async throws {
        try await cli.run(["prune"])
    }

    /// Recreate a container with edited settings: delete it, then `run` a new
    /// one built from its (edited) config. Volume data persists.
    ///
    /// If the edited container fails to start, the original is run again from
    /// its previous settings, so a bad edit never loses the container; the
    /// error is then ``EngineError/rolledBack(_:)``.
    public func recreate(_ container: Container, edits: ContainerEdits) async throws {
        // Strip the image's entrypoint from the inspected command (see ContainerRecreate).
        let entrypoint: [String]
        do {
            let data = try await cli.data(["image", "inspect", container.configuration.image.reference])
            entrypoint = ContainerRecreate.parseEntrypoint(data, architecture: container.configuration.platform.architecture)
        } catch {
            entrypoint = []
        }
        let edited = ContainerRecreate.runArguments(for: container, edits: edits, imageEntrypoint: entrypoint)
        let original = ContainerRecreate.runArguments(for: container, edits: ContainerRecreate.currentEdits(for: container),
                                                      imageEntrypoint: entrypoint)
        try await delete(container.id, force: true)
        do {
            try await cli.run(edited)
        } catch {
            // The edited container may exist half-created; clear it before restoring.
            try? await delete(container.id, force: true)
            try await cli.run(original)
            if !container.state.isRunning { try? await stop(container.id) }
            throw EngineError.rolledBack(error.localizedDescription)
        }
    }

    /// A single `container stats --no-stream --format json <id>` sample.
    /// Polled on an interval to drive live gauges and charts.
    public func stats(_ id: String) async throws -> ContainerStats {
        let samples = try await cli.decode(
            [ContainerStats].self,
            ["stats", "--no-stream", "--format", "json", id]
        )
        guard let first = samples.first else {
            throw EngineError.notFound(String(localized: "No stats for container \(id) (is it running?)."))
        }
        return first
    }
}
