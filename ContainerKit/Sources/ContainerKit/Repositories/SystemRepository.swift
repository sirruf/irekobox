import Foundation

/// Domain service for `container system` — the service gate and disk usage.
public struct SystemRepository: Sendable {
    private let cli: any ContainerCommanding

    public init(cli: any ContainerCommanding) {
        self.cli = cli
    }

    /// `container system status --format json`.
    ///
    /// Returns `nil` if services are not running (the CLI reports "apiserver is
    /// not running"), so callers can render a "Start services" gate. Any other
    /// failure is thrown — it must not masquerade as "stopped".
    public func status() async throws -> SystemStatus? {
        do {
            return try await cli.decode(SystemStatus.self, ["system", "status", "--format", "json"],
                                        alsoAccepting: [1])
        } catch EngineError.servicesNotRunning {
            return nil
        }
    }

    /// `container system df --format json`.
    public func diskUsage() async throws -> SystemDiskUsage {
        try await cli.decode(SystemDiskUsage.self, ["system", "df", "--format", "json"])
    }

    /// `container builder status --format json` → running state + optional id.
    public func builderStatus() async throws -> BuilderStatus {
        let data = try await cli.data(["builder", "status", "--format", "json"])
        return BuilderStatus.parse(data)
    }

    public func startServices() async throws {
        // Without the flag a first start asks on stdin whether to download the
        // default kernel, and a GUI has no stdin to answer it.
        try await cli.run(["system", "start", "--enable-kernel-install"])
    }

    public func stopServices() async throws {
        try await cli.run(["system", "stop"])
    }
}
