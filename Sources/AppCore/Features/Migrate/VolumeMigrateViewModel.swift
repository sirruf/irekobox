import Foundation
import Observation
import ContainerKit
import EngineCore
import MigrationKit

/// Migrates Docker **named** volume data into `container` volumes.
/// Bind mounts (host folders) are intentionally out of scope — they need no copy.
@MainActor
@Observable
final class VolumeMigrateViewModel {
    private let cli: ContainerCLI
    let dockerPath: String?
    private let helperImage = "alpine"

    var volumes: [DockerVolume] = []
    var isLoading = false
    var migrating: String?      // name of the volume currently migrating
    var status: String?
    var error: String?
    /// The docker command is there but no Docker engine answers it.
    var dockerDown = false

    var dockerAvailable: Bool { dockerPath != nil }

    init(cli: ContainerCLI) {
        self.cli = cli
        self.dockerPath = DockerEnvironment.dockerPath()
    }

    func loadVolumes() async {
        guard let dockerPath else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let output = try await ProcessRunner.run(executable: dockerPath, ["volume", "ls", "--format", "{{json .}}"])
            let decoder = JSONDecoder()
            volumes = output
                .split(whereSeparator: \.isNewline)
                .compactMap { try? decoder.decode(DockerVolume.self, from: Data($0.utf8)) }
                .sorted { $0.name < $1.name }
            error = nil
            dockerDown = false
        } catch {
            dockerDown = await !Self.desktopAnswers()
            self.error = dockerDown ? nil : error.localizedDescription
        }
    }

    private static func desktopAnswers() async -> Bool {
        (try? await UnixHTTP(socketPath: DesktopMigration.defaultSourceSocket).get("/_ping", timeout: 3))?.ok == true
    }

    func migrate(_ volume: DockerVolume) async {
        guard let dockerPath, migrating == nil else { return }
        migrating = volume.name
        defer { migrating = nil }
        status = nil
        error = nil

        let tarDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ib-vol-\(UUID().uuidString)", isDirectory: true)
        let containerVolume = volume.name

        do {
            try FileManager.default.createDirectory(at: tarDir, withIntermediateDirectories: true)
            try await ensureHelperImage(dockerPath: dockerPath)

            let steps = VolumeMigration().copyNamed(
                dockerVolume: volume.name,
                containerVolume: containerVolume,
                tarDirectory: tarDir.path,
                tarName: "data.tar",
                helperImage: helperImage
            )
            for step in steps {
                status = step.summary + "…"
                switch step.tool {
                case .docker:    try await ProcessRunner.run(executable: dockerPath, step.arguments)
                case .container: try await cli.run(step.arguments)
                }
            }
            status = String(localized: "Migrated \(volume.name) → container volume \(containerVolume).")
        } catch {
            self.error = error.localizedDescription
            status = nil
        }
        try? FileManager.default.removeItem(at: tarDir)
    }

    /// Make sure the `tar` helper image exists in both runtimes.
    private func ensureHelperImage(dockerPath: String) async throws {
        if (try? await ProcessRunner.run(executable: dockerPath, ["image", "inspect", helperImage])) == nil {
            status = String(localized: "Pulling \(helperImage) (Docker)…")
            try await ProcessRunner.run(executable: dockerPath, ["pull", helperImage])
        }
        if (try? await cli.run(["image", "inspect", helperImage])) == nil {
            status = String(localized: "Pulling \(helperImage) (container)…")
            try await cli.run(["image", "pull", helperImage])
        }
    }
}
