import Foundation
import Observation
import MigrationKit
import ContainerKit

/// Drives the Migrate screen: translate a `docker run …` command into
/// `container run …`, then optionally execute it.
@MainActor
@Observable
final class MigrateViewModel {
    private let cli: ContainerCLI

    var input: String = "docker run -d --name web -p 8080:80 nginx:latest"
    var translation: DockerRunTranslation?
    var error: String?
    var isRunning = false
    var runResult: String?

    init(cli: ContainerCLI) {
        self.cli = cli
    }

    func translate() {
        do {
            translation = try DockerRunTranslator().translate(input)
            error = nil
            runResult = nil
        } catch {
            self.error = error.localizedDescription
            translation = nil
        }
    }

    func run() async {
        guard let translation, !isRunning else { return }
        isRunning = true
        runResult = nil
        error = nil
        do {
            try await cli.run(translation.arguments)
            runResult = String(localized: "Started \(translation.image).")
        } catch {
            self.error = error.localizedDescription
        }
        isRunning = false
    }
}
