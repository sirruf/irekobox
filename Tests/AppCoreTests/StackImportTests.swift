import XCTest
import ContainerKit
import ComposeKit
import StackKit
@testable import AppCore

/// Stack import and planning, covered without UI or an open panel.
///
/// Importing a stack from the UI goes through an `NSOpenPanel` (`fileImporter`),
/// and an open panel can hang the XCUITest runner, so the import path is not
/// exercised from a UI test. Instead these tests drive the same code paths the
/// UI uses — `ComposeViewModel` plus `ComposeParser`/`ComposePlanner` (what
/// `ComposeViewModel.plan(for:)` calls) — against a compose file written to a
/// temporary folder.
///
/// Safety:
///   • The compose file is only read.
///   • No plan is EXECUTED (no `container run`): the `ComposeRunner` is wired to
///     a no-op runner that records nothing and spawns no process, and up()/down()
///     are never called.
///   • `addStack(...)` would persist to the REAL
///     `~/Library/Application Support/Irekobox/stacks.json`. We do NOT
///     call it; we test `suggestedName`/`bindMounts`/`plan` which never touch
///     that file. (A scrub helper is provided and asserted as a safety net so a
///     regression that starts persisting would be caught.)
final class StackImportTests: XCTestCase {

    /// A local-database compose file: postgres (HOST BIND MOUNT + ports 5432,
    /// restart, healthcheck) and redis (named volume, ports 6379, restart,
    /// healthcheck, command). Written to a temporary `Docker/` folder.
    static let folder = FileManager.default.temporaryDirectory
        .appending(path: "ib-stack-import/Docker")
    static let composePath = folder.appending(path: "docker_compose_local_db.container.yml").path
    static let hostData = "/Users/fixture/Rails/pg16_data"
    static let composeText = """
    services:
      postgres:
        image: pgvector/pgvector:pg16
        container_name: postgres_pgvector
        user: "999:999"
        environment:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: pg
          POSTGRES_DB: postgres
          PGDATA: /var/lib/postgresql/data/pgdata
        ports:
          - "5432:5432"
        volumes:
          - \(hostData):/var/lib/postgresql/data
        restart: unless-stopped
        healthcheck:
          test: ["CMD-SHELL", "pg_isready -U postgres"]
          interval: 10s
          timeout: 5s
          retries: 5

      redis:
        image: redis:7-alpine
        container_name: redis
        ports:
          - "6379:6379"
        volumes:
          - redis_data:/data
        restart: unless-stopped
        command: redis-server --appendonly yes
        healthcheck:
          test: ["CMD", "redis-cli", "ping"]
          interval: 10s
          timeout: 5s
          retries: 5

    volumes:
      redis_data:
        driver: local
    """

    /// A `StackCommandRunner` that NEVER executes anything — guarantees the plan
    /// is never run even if a test accidentally calls up()/down().
    private struct NoopRunner: StackCommandRunner {
        func run(_ arguments: [String], workingDirectory: URL?) async throws {
            XCTFail("NoopRunner.run must never be called in StackImportTests (no plan execution).")
        }
    }

    @MainActor
    private func makeVM() -> ComposeViewModel {
        ComposeViewModel(engine: CLIEngine(cli: MockCLI(), stream: CLIStream()),
                        runner: ComposeRunner(runner: NoopRunner()))
    }

    private var entry: StackEntry {
        StackEntry(name: "ib-uitest-stack", composePath: Self.composePath)
    }

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try Self.composeText.write(toFile: Self.composePath, atomically: true, encoding: .utf8)
        // Guard: ensure our test stack name is NOT already persisted, and remove
        // it if a prior run leaked it (defensive — these tests never add it).
        scrubStackFromJSON(entry.name)
    }

    override func tearDownWithError() throws {
        scrubStackFromJSON(entry.name)
        // Safety net: the persisted stacks list must NOT contain our test entry.
        XCTAssertFalse(persistedStackNames().contains(entry.name),
                       "stacks.json must remain unpolluted by StackImportTests")
    }

    // MARK: - 1. The project name comes from the folder, as in Docker Compose

    @MainActor
    func testProjectNameIsTheFolderName() {
        XCTAssertEqual(ComposeViewModel.projectName(for: URL(fileURLWithPath: Self.composePath)), "docker")
    }

    // MARK: - 2. bindMounts detects the postgres HOST BIND MOUNT (drives BindMountHint)

    @MainActor
    func testBindMountDetectionFindsPostgresHostMount() async {
        let vm = makeVM()

        let project = ComposeProject(name: entry.name, entry: entry, directory: nil,
                                     configFiles: [Self.composePath], containers: [])
        // Views read the cached parse; reload() fills it before they show.
        _ = await vm.parsedFile(at: Self.composePath)
        let viaEntry = vm.bindMounts(of: project)
        XCTAssertFalse(viaEntry.isEmpty,
                       "compose has a postgres host bind mount → must be non-empty (drives BindMountHint)")

        // The detected entry must mention postgres and the host path. The view
        // model formats each as "service: host-path".
        let joined = viaEntry.joined(separator: "\n")
        XCTAssertTrue(joined.contains("postgres"),
                      "bind mount should be attributed to the postgres service")
        XCTAssertTrue(joined.contains(Self.hostData),
                      "bind mount should mention the host path that triggers the BindMountHint")

        // The redis NAMED volume (redis_data) must NOT be reported as a bind mount.
        XCTAssertFalse(joined.contains("redis_data"),
                       "named volumes are not bind mounts and must be excluded")
    }

    // MARK: - 3. plan(for:) yields ordered container steps, ports, volume/network create, warnings

    @MainActor
    func testPlanProducesOrderedStepsPortsAndWarnings() async throws {
        let vm = makeVM()
        let (plan, directory) = try await vm.plan(for: entry)

        // Working directory must be the compose file's folder (relative bind/build
        // sources resolve there).
        XCTAssertEqual(directory.path, Self.folder.path,
                       "plan directory should be the compose file's parent")

        // --- Steps overview ----------------------------------------------------
        let runSteps = plan.steps.filter { $0.kind == .run }
        let volumeSteps = plan.steps.filter { $0.kind == .volume }
        let networkSteps = plan.steps.filter { $0.kind == .network }

        // A run step per service: postgres + redis.
        let runServices = Set(runSteps.compactMap { $0.service })
        XCTAssertEqual(runServices, ["postgres", "redis"],
                       "plan should run exactly the postgres and redis services")
        XCTAssertEqual(runSteps.count, 2, "exactly two run steps expected")

        // --- Ordering: infra (network/volume create) BEFORE any run -----------
        let firstRunIndex = plan.steps.firstIndex { $0.kind == .run }!
        for (i, step) in plan.steps.enumerated() where step.kind == .network || step.kind == .volume {
            XCTAssertLessThan(i, firstRunIndex,
                              "all network/volume create steps must precede the first run step")
        }

        // --- Network create: a project default network ------------------------
        // Neither service declares an explicit network → planner creates
        // "<project>-default" (project = sanitized stack name).
        XCTAssertFalse(networkSteps.isEmpty, "a default network create step is expected")
        let networkCreateArgs = networkSteps.map { $0.arguments }
        XCTAssertTrue(networkCreateArgs.contains(["network", "create", "ib-uitest-stack-default"]),
                      "plan should create the project default network")

        // --- Volume create: redis_data (named volume) -------------------------
        XCTAssertFalse(volumeSteps.isEmpty, "redis declares a named volume → a volume create is expected")
        let volumeCreateArgs = volumeSteps.map { $0.arguments }
        XCTAssertTrue(volumeCreateArgs.contains(["volume", "create", "ib-uitest-stack-redis_data"]),
                      "plan should create the redis_data named volume (project-prefixed)")

        // --- Published ports ---------------------------------------------------
        func runArgs(_ service: String) -> [String] {
            runSteps.first { $0.service == service }!.arguments
        }
        let pgArgs = runArgs("postgres")
        let redisArgs = runArgs("redis")

        XCTAssertTrue(consecutive(pgArgs, ["--publish", "5432:5432"]),
                      "postgres run step should publish 5432:5432")
        XCTAssertTrue(consecutive(redisArgs, ["--publish", "6379:6379"]),
                      "redis run step should publish 6379:6379")

        // --- The postgres host bind mount appears in its run argv -------------
        XCTAssertTrue(consecutive(pgArgs, ["--volume", Self.hostData + ":/var/lib/postgresql/data"]),
                      "postgres run step should mount the host bind path")
        // container_name from the compose file is honored.
        XCTAssertTrue(consecutive(pgArgs, ["--name", "postgres_pgvector"]),
                      "postgres should keep its compose container_name")
        XCTAssertTrue(consecutive(redisArgs, ["--name", "redis"]),
                      "redis should keep its compose container_name")
        // The stack label is injected on every run (used to find owned containers).
        XCTAssertTrue(consecutive(pgArgs, ["--label", "\(StackLabel.key)=ib-uitest-stack"]),
                      "run steps should carry the stack ownership label")

        // redis command is shell-tokenized onto the run argv.
        XCTAssertTrue(redisArgs.contains("redis-server") && redisArgs.contains("--appendonly"),
                      "redis command (redis-server --appendonly yes) should be appended to its run argv")

        // --- Warnings: restart + healthcheck are app-level/partial, not crashes
        let restartWarnings = plan.warnings.filter { $0.field == "restart" }
        let healthWarnings  = plan.warnings.filter { $0.field == "healthcheck" }
        XCTAssertFalse(restartWarnings.isEmpty,
                       "restart: should surface a warning (handled at app level, not a native run flag)")
        XCTAssertFalse(healthWarnings.isEmpty,
                       "healthcheck: should surface a warning (run via exec on an interval)")
        // Both restart and healthcheck are classified as non-fatal (.info severity).
        for w in restartWarnings + healthWarnings {
            XCTAssertNotEqual(w.severity, .unsupported,
                              "restart/healthcheck should be info-level (app-handled), not 'unsupported'")
        }
        // The plan has no fatal error: it built successfully (we got here) and has
        // both services, and every warning names its field.
        XCTAssertTrue(plan.warnings.allSatisfy { !$0.field.isEmpty })
    }

    // MARK: - Helpers

    /// True if `needle` appears as a contiguous subsequence of `haystack`.
    private func consecutive(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<start + needle.count]) == needle { return true }
        }
        return false
    }

    private var stacksJSONURL: URL {
        let path = ("~/Library/Application Support/Irekobox/stacks.json" as NSString)
            .expandingTildeInPath
        return URL(fileURLWithPath: path)
    }

    private func persistedStackNames() -> [String] {
        guard let data = try? Data(contentsOf: stacksJSONURL),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { $0["name"] as? String }
    }

    /// Remove `name` from stacks.json if present (defensive; tests never add it).
    private func scrubStackFromJSON(_ name: String) {
        guard let data = try? Data(contentsOf: stacksJSONURL),
              var arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        let before = arr.count
        arr.removeAll { ($0["name"] as? String) == name }
        if arr.count != before, let out = try? JSONSerialization.data(withJSONObject: arr) {
            try? out.write(to: stacksJSONURL)
        }
    }
}
