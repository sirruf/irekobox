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

    func testBindMountDetection() async throws {
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
        let model = makeVM()
        _ = await model.parsedFile(at: file.path)
        XCTAssertEqual(model.bindMounts(of: project), ["db: /Users/me/data", "web: ./site"])
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

    /// A compose file is parsed once per version, off the main actor, and
    /// read again when it changes; views see the last parse meanwhile.
    func testParsedFilesAreCachedByModificationDateAndSize() async throws {
        let file = try temporaryFolder().appending(path: "compose.yaml")
        try "services:\n  web:\n    image: nginx\n".write(to: file, atomically: true, encoding: .utf8)
        let model = makeVM()
        let entry = StackEntry(name: "x", composePath: file.path)
        let project = ComposeProject(name: "x", entry: entry, directory: nil, configFiles: [file.path], containers: [])

        XCTAssertNil(model.file(of: project), "nothing cached yet; a parse starts in the background")
        _ = await model.parsedFile(at: file.path)
        XCTAssertEqual(model.file(of: project)?.services.keys.sorted(), ["web"])
        _ = await model.parsedFile(at: file.path)
        XCTAssertEqual(model.parseCount, 1, "an unchanged file is not parsed again")

        try "services:\n  web:\n    image: nginx\n  db:\n    image: postgres\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(model.file(of: project)?.services.count, 1, "the last parse serves the view while the new one runs")
        _ = await model.parsedFile(at: file.path)
        XCTAssertEqual(model.file(of: project)?.services.count, 2)
        XCTAssertEqual(model.parseCount, 2)

        let (plan, directory) = try await model.plan(for: entry)
        XCTAssertEqual(plan.steps.filter { $0.kind == .run }.compactMap(\.service).sorted(), ["db", "web"])
        XCTAssertEqual(directory.path, file.deletingLastPathComponent().path)
        XCTAssertEqual(model.parseCount, 2, "the plan reads the cached parse")
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
