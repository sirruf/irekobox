import XCTest
import ContainerKit
import StackKit
import ComposeKit
@testable import AppCore

@MainActor
final class ComposeViewModelTests: XCTestCase {
    private func makeVM() -> ComposeViewModel {
        ComposeViewModel(engine: CLIEngine(cli: MockCLI(), stream: CLIStream()),
                         runner: ComposeRunner(runner: ContainerCLI()))
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ib-compose-\(UUID().uuidString)/Shop App")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func testBindMountDetection() throws {
        let yaml = """
        services:
          db:
            image: postgres
            volumes:
              - /Users/me/data:/var/lib/postgresql/data
              - cache:/cache
          web:
            image: nginx
            volumes:
              - ./site:/usr/share/nginx/html
        volumes:
          cache:
        """
        let file = try temporaryFolder().appending(path: "compose.yaml")
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        let project = ComposeProject(name: "x", entry: StackEntry(name: "x", composePath: file.path),
                                     directory: nil, configFiles: [file.path], containers: [])
        // Only the two host-path binds; the named `cache` volume is excluded.
        XCTAssertEqual(makeVM().bindMounts(of: project), ["db: /Users/me/data", "web: ./site"])
    }

    /// A folder opens its compose file; the name is the folder's, or `name:`.
    func testComposeFileAndNameFromAFolder() throws {
        let folder = try temporaryFolder()
        XCTAssertNil(ComposeViewModel.composeFile(at: folder))
        let file = folder.appending(path: "docker-compose.yml")
        try "services:\n  web:\n    image: nginx\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(ComposeViewModel.composeFile(at: folder)?.path, file.path)
        XCTAssertEqual(ComposeViewModel.composeFile(at: file)?.path, file.path)
        XCTAssertEqual(ComposeViewModel.projectName(for: file), "shop-app")
        try "name: Store\nservices:\n  web:\n    image: nginx\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(ComposeViewModel.projectName(for: file), "store")
    }

    /// Start runs only what's missing; existing containers are started instead.
    func testMissingStepsSkipExistingContainers() {
        let plan = ComposePlan(projectName: "shop", steps: [
            PlanStep(kind: .network, arguments: ["network", "create", "shop-default"]),
            PlanStep(kind: .build, service: "web", arguments: ["build"]),
            PlanStep(kind: .run, service: "web", containerName: "shop-web", arguments: ["run"]),
            PlanStep(kind: .run, service: "db", containerName: "shop-db", arguments: ["run"]),
        ], warnings: [])
        let missing = ComposeViewModel.missing(from: plan, existing: ["shop-web"])
        XCTAssertEqual(missing.steps.map(\.kind), [.network, .run])
        XCTAssertEqual(missing.steps.last?.containerName, "shop-db")
    }
}
