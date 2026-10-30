import Foundation

/// Domain service for `container volume`.
public struct VolumeRepository: Sendable {
    private let cli: any ContainerCommanding

    public init(cli: any ContainerCommanding) {
        self.cli = cli
    }

    public func list() async throws -> [Volume] {
        try await cli.decode([Volume].self, ["volume", "ls", "--format", "json"])
    }

    public func create(_ name: String) async throws {
        try await cli.run(["volume", "create", name])
    }

    /// `container volume create [--label k=v]… [--opt k=v]… [-s size] <name>`.
    public func create(_ name: String, labels: [String: String], size: String?, options: [String: String]) async throws {
        var arguments = ["volume", "create"]
        for (key, value) in labels.sorted(by: { $0.key < $1.key }) { arguments += ["--label", "\(key)=\(LabelValue.encode(value))"] }
        for (key, value) in options.sorted(by: { $0.key < $1.key }) { arguments += ["--opt", "\(key)=\(value)"] }
        if let size { arguments += ["-s", size] }
        try await cli.run(arguments + [name])
    }

    public func delete(_ name: String) async throws {
        try await cli.run(["volume", "delete", name])
    }

    public func prune() async throws {
        try await cli.run(["volume", "prune"])
    }
}
