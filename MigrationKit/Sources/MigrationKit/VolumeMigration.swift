import Foundation

/// How a compose/Docker "volume" entry should be migrated.
public enum VolumeKind: String, Sendable, Hashable {
    /// A Docker-managed named volume — its data must be copied.
    case named
    /// A host folder bind mount — reused directly, no copy needed.
    case bind
}

/// Plans migrating volume data from Docker to `container`.
///
/// Named volumes are copied through a host tar (`docker run … tar cf` →
/// `container run … tar xf`). Bind mounts need no copy — the same host path is
/// mounted into `container` with `-v <host>:<target>`.
public struct VolumeMigration: Sendable {
    public init() {}

    /// Classify a volume `source`: a path-like source is a bind mount.
    public func classify(_ source: String) -> VolumeKind {
        let s = source.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("/") || s.hasPrefix("./") || s.hasPrefix("../") || s.hasPrefix("~") {
            return .bind
        }
        return .named
    }

    /// Bind mount: nothing to copy. Returns the `container run` mount to reuse.
    public func bindMount(hostPath: String, target: String) -> MigrationCommand {
        MigrationCommand(
            tool: .container,
            arguments: ["run", "-v", "\(hostPath):\(target)"],
            summary: String(localized: "Bind mount \(hostPath) → \(target) (no copy needed)")
        )
    }

    /// Named volume copy: Docker volume → host tar → `container` volume.
    ///
    /// - `tarDirectory` is a host folder mounted at `/backup` in both runtimes.
    /// - `helperImage` must contain `tar` and exist in **both** Docker and
    ///   `container` (e.g. `alpine`).
    public func copyNamed(
        dockerVolume: String,
        containerVolume: String,
        tarDirectory: String,
        tarName: String,
        helperImage: String = "alpine"
    ) -> [MigrationCommand] {
        let backupTar = "/backup/\(tarName)"
        return [
            MigrationCommand(
                tool: .docker,
                arguments: ["run", "--rm",
                            "-v", "\(dockerVolume):/from:ro",
                            "-v", "\(tarDirectory):/backup",
                            helperImage, "tar", "cf", backupTar, "-C", "/from", "."],
                summary: String(localized: "Export Docker volume \(dockerVolume)")
            ),
            MigrationCommand(
                tool: .container,
                arguments: ["volume", "create", containerVolume],
                summary: String(localized: "Create container volume \(containerVolume)")
            ),
            MigrationCommand(
                tool: .container,
                arguments: ["run", "--rm",
                            "-v", "\(containerVolume):/to",
                            "-v", "\(tarDirectory):/backup",
                            helperImage, "tar", "xf", backupTar, "-C", "/to"],
                summary: String(localized: "Import data into \(containerVolume)")
            ),
        ]
    }
}
