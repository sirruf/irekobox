import XCTest
@testable import StackKit
import ComposeKit

/// Records executed argv and can simulate failures for specific commands.
actor MockRunner: StackCommandRunner {
    private(set) var commands: [[String]] = []
    /// If any argument contains one of these substrings, throw `error`.
    let failSubstrings: [String]
    let error: Error

    init(failSubstrings: [String] = [], error: Error = MockError.boom) {
        self.failSubstrings = failSubstrings
        self.error = error
    }

    func run(_ arguments: [String], workingDirectory: URL?) async throws {
        commands.append(arguments)
        if failSubstrings.contains(where: { sub in arguments.contains { $0.contains(sub) } }) {
            throw error
        }
    }
}

enum MockError: Error, LocalizedError {
    case boom
    case alreadyExists
    case notFound
    var errorDescription: String? {
        switch self {
        case .boom: return "command failed"
        case .alreadyExists: return "network already exists"
        case .notFound: return "container not found"
        }
    }
}

final class ComposeRunnerTests: XCTestCase {

    private func samplePlan() throws -> ComposePlan {
        let yaml = """
        name: shop
        services:
          db:
            image: postgres:16
            networks: [backend]
          web:
            image: nginx
            depends_on: [db]
            networks: [backend]
        networks:
          backend:
        volumes:
          data:
        """
        let parsed = try ComposeParser(environment: [:]).parse(yaml)
        return try ComposePlanner().plan(parsed)
    }

    func testUpRunsEveryStepInOrder() async throws {
        let plan = try samplePlan()
        let mock = MockRunner()
        let outcomes = await ComposeRunner(runner: mock).up(plan)

        let executed = await mock.commands
        XCTAssertEqual(executed, plan.steps.map(\.arguments))
        XCTAssertTrue(outcomes.allSucceeded)
        // db started before web
        let runNames = outcomes.filter { $0.step.kind == .run }.compactMap(\.step.containerName)
        XCTAssertEqual(runNames, ["shop-db", "shop-web"])
    }

    func testCreateAlreadyExistsIsSkippedNotFatal() async throws {
        let plan = try samplePlan()
        let mock = MockRunner(failSubstrings: ["create"], error: MockError.alreadyExists)
        let outcomes = await ComposeRunner(runner: mock).up(plan)

        // network/volume creates skipped, but run steps still executed.
        let creates = outcomes.filter { $0.step.kind == .network || $0.step.kind == .volume }
        XCTAssertTrue(creates.allSatisfy { if case .skipped = $0.status { return true } else { return false } })
        XCTAssertTrue(outcomes.contains { $0.step.kind == .run })
        XCTAssertTrue(outcomes.allSucceeded) // skipped is not a failure
    }

    func testHardFailureStops() async throws {
        let plan = try samplePlan()
        // Fail on running the db container (hard failure, not idempotent).
        let mock = MockRunner(failSubstrings: ["shop-db"], error: MockError.boom)
        let outcomes = await ComposeRunner(runner: mock).up(plan, stopOnFailure: true)

        XCTAssertFalse(outcomes.allSucceeded)
        // web run must NOT have executed after db failed.
        let ranWeb = await mock.commands.contains { $0.contains("shop-web") }
        XCTAssertFalse(ranWeb)
    }

    func testDownStopsAndDeletesInReverse() async throws {
        let plan = try samplePlan()
        let mock = MockRunner()
        _ = await ComposeRunner(runner: mock).down(plan, removeVolumes: true)

        let executed = await mock.commands
        // web torn down before db (reverse of up order)
        XCTAssertTrue(executed.contains(["stop", "shop-web"]))
        XCTAssertTrue(executed.contains(["delete", "shop-web"]))
        XCTAssertLessThan(executed.firstIndex(of: ["stop", "shop-web"])!,
                          executed.firstIndex(of: ["stop", "shop-db"])!)
        // volumes + networks removed
        XCTAssertTrue(executed.contains(["volume", "delete", "shop-data"]))
        XCTAssertTrue(executed.contains(["network", "delete", "shop-backend"]))
    }
}
