import Foundation
import Observation
import ContainerKit
import EngineCore
import MigrationKit

/// Imports local Docker images into `container` via `docker save` →
/// `container image load`, cleaning up the temp tar.
@MainActor
@Observable
final class DockerImportViewModel {
    private let cli: ContainerCLI
    let dockerPath: String?

    var images: [DockerImage] = []
    var isLoadingImages = false
    var isImporting = false
    var status: String?
    var error: String?
    /// The docker command is there but no Docker engine answers it.
    var dockerDown = false

    var dockerAvailable: Bool { dockerPath != nil }

    init(cli: ContainerCLI) {
        self.cli = cli
        self.dockerPath = DockerEnvironment.dockerPath()
    }

    func loadImages() async {
        guard let dockerPath else { return }
        isLoadingImages = true
        defer { isLoadingImages = false }
        do {
            let output = try await ProcessRunner.run(executable: dockerPath, ["image", "ls", "--format", "{{json .}}"])
            let decoder = JSONDecoder()
            images = output
                .split(whereSeparator: \.isNewline)
                .compactMap { try? decoder.decode(DockerImage.self, from: Data($0.utf8)) }
                .filter(\.isValid)
                .sorted { $0.reference < $1.reference }
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

    func importImage(_ reference: String) async {
        guard let dockerPath, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        status = nil
        error = nil

        let tar = FileManager.default.temporaryDirectory
            .appendingPathComponent("ib-import-\(UUID().uuidString).tar")
        let steps = DockerImageImport().plan(image: reference, tarPath: tar.path)

        do {
            for step in steps {
                status = step.summary + "…"
                switch step.tool {
                case .docker:    try await ProcessRunner.run(executable: dockerPath, step.arguments)
                case .container: try await cli.run(step.arguments)
                }
            }
            status = String(localized: "Imported \(reference).")
        } catch {
            self.error = error.localizedDescription
            status = nil
        }
        try? FileManager.default.removeItem(at: tar)
    }
}
