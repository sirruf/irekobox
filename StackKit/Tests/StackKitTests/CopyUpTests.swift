import XCTest
@testable import StackKit
import ComposeKit
import ContainerKit

/// Fresh volumes are filled from the image before a service mounts them.
final class CopyUpTests: XCTestCase {

    private func plan(_ yaml: String) throws -> ComposePlan {
        try ComposePlanner().plan(try ComposeParser(environment: [:]).parse(yaml))
    }

    private let postgres = """
    name: shop
    services:
      db:
        image: postgres:16
        volumes: [data:/var/lib/postgresql/data]
    volumes:
      data:
    """

    func testFreshNamedVolumeIsFilledBeforeTheServiceStarts() async throws {
        let mock = MockRunner()
        let outcomes = await ComposeRunner(runner: mock).up(try plan(postgres))
        XCTAssertTrue(outcomes.allSucceeded)

        let executed = await mock.commands
        let create = executed.firstIndex(of: ["volume", "create", "shop-data"])!
        let helperRun = executed.firstIndex { $0.first == "run" && $0.contains("shop-db-copyup-0") }!
        let helperDelete = executed.firstIndex(of: ["delete", "--force", "shop-db-copyup-0"])!
        let serviceRun = executed.firstIndex { $0.first == "run" && $0.contains("shop-db") && !$0.contains("shop-db-copyup-0") }!
        XCTAssertLessThan(create, helperRun)
        XCTAssertLessThan(helperRun, helperDelete)
        XCTAssertLessThan(helperDelete, serviceRun, "the helper is removed before the service mounts the volume")

        let helper = executed[helperRun]
        XCTAssertTrue(helper.contains("shop-data:\(VolumeCopyUp.mountPoint)"))
        XCTAssertTrue(helper.contains("postgres:16"))
        XCTAssertEqual(helper[helper.firstIndex(of: "--user")! + 1], "0")
        let script = helper.last!
        XCTAssertTrue(script.contains("lost+found"))
        XCTAssertTrue(script.contains("'/var/lib/postgresql/data'"))
        XCTAssertFalse(helper.contains("--detach"), "the helper runs in the foreground, so `run` returns once it exited")
        // The helper is not reported as a step; the service step is.
        XCTAssertEqual(outcomes.map(\.step.kind), [.network, .volume, .run])
    }

    func testAnExistingVolumeIsLeftAlone() async throws {
        let mock = MockRunner(failSubstrings: ["create"], error: MockError.alreadyExists)
        let outcomes = await ComposeRunner(runner: mock).up(try plan(postgres))
        XCTAssertTrue(outcomes.allSucceeded)
        let executed = await mock.commands
        XCTAssertFalse(executed.contains { $0.contains("shop-db-copyup-0") })
        XCTAssertEqual(executed.filter { $0.first == "run" }.count, 1)
    }

    func testAVolumeSharedByTwoServicesIsFilledOnce() async throws {
        let yaml = """
        name: shop
        services:
          a:
            image: alpine
            volumes: [shared:/srv]
          b:
            image: alpine
            volumes: [shared:/srv]
        volumes:
          shared:
        """
        let mock = MockRunner()
        _ = await ComposeRunner(runner: mock).up(try plan(yaml))
        let helpers = await mock.commands.filter { $0.contains("--entrypoint") }
        XCTAssertEqual(helpers.count, 1)
        XCTAssertTrue(helpers[0].contains("shop-a-copyup-0"))
    }

    func testBindMountsAreNotFilled() async throws {
        let yaml = """
        name: shop
        services:
          web:
            image: nginx
            volumes: ["./site:/usr/share/nginx/html", "/tmp/x:/x"]
        """
        let mock = MockRunner()
        _ = await ComposeRunner(runner: mock).up(try plan(yaml))
        let helpers = await mock.commands.filter { $0.contains("--entrypoint") }
        XCTAssertTrue(helpers.isEmpty)
    }

    func testAnonymousVolumeIsNamedCreatedAndFilled() async throws {
        let yaml = """
        name: shop
        services:
          web:
            image: nginx
            volumes: [/var/cache/nginx]
        """
        let mock = MockRunner()
        let outcomes = await ComposeRunner(runner: mock).up(try plan(yaml))
        XCTAssertTrue(outcomes.allSucceeded)

        let name = VolumeCopyUp.anonymousVolumeName(container: "shop-web", path: "/var/cache/nginx")
        let executed = await mock.commands
        XCTAssertEqual(executed[0], ["network", "create", "shop-default"])
        XCTAssertEqual(executed[1], ["volume", "create", name])
        XCTAssertTrue(executed[2].contains("shop-web-copyup-0"))
        XCTAssertTrue(executed[2].contains("\(name):\(VolumeCopyUp.mountPoint)"))
        XCTAssertEqual(executed[3], ["delete", "--force", "shop-web-copyup-0"])
        let service = executed[4]
        XCTAssertTrue(service.contains("--volume"))
        XCTAssertTrue(service.contains("\(name):/var/cache/nginx"))
        XCTAssertFalse(service.contains("--mount"))
        // The create is reported as a volume step of the service.
        XCTAssertEqual(outcomes.map(\.step.kind), [.network, .volume, .run])
        XCTAssertEqual(outcomes[1].step.service, "web")
        XCTAssertEqual(outcomes[2].step.arguments, service)
    }

    func testReadOnlyAnonymousVolumeKeepsItsMode() throws {
        let step = PlanStep(kind: .run, service: "web", containerName: "shop-web",
                            arguments: ["run", "--detach", "--name", "shop-web",
                                        "--mount", "type=volume,target=/data,readonly", "nginx"])
        let run = RunArguments(step.arguments)!
        let named = ComposeRunner.naming(run.anonymousVolumes, of: step, container: "shop-web")
        let name = VolumeCopyUp.anonymousVolumeName(container: "shop-web", path: "/data")
        XCTAssertEqual(named.arguments, ["run", "--detach", "--name", "shop-web", "--volume", "\(name):/data:ro", "nginx"])
    }

    func testAHelperThatCannotBeRemovedStopsTheService() async throws {
        // `delete` fails hard: the volume may still be mounted by the helper.
        let mock = MockRunner(failSubstrings: ["delete"], error: MockError.boom)
        let outcomes = await ComposeRunner(runner: mock).up(try plan(postgres))
        XCTAssertFalse(outcomes.allSucceeded)
        let run = outcomes.first { $0.step.kind == .run }!
        guard case .failed(let message) = run.status else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.contains("shop-db-copyup-0"))
        let executed = await mock.commands
        XCTAssertFalse(executed.contains { $0.first == "run" && $0.contains("--detach") }, "the service must not start")
    }

    func testAHelperNeverMadeIsNoError() async throws {
        // The image has no shell: the helper run fails, and there is nothing to delete.
        actor Failing: StackCommandRunner {
            var commands: [[String]] = []
            func run(_ arguments: [String], workingDirectory: URL?) async throws {
                commands.append(arguments)
                if arguments.contains("--entrypoint") { throw MockError.boom }
                if arguments.first == "delete" { throw MockError.notFound }
            }
        }
        let runner = Failing()
        let outcomes = await ComposeRunner(runner: runner).up(try plan(postgres))
        XCTAssertTrue(outcomes.allSucceeded)
        let started = await runner.commands.contains { $0.first == "run" && $0.contains("--detach") }
        XCTAssertTrue(started)
    }

    func testDownWithVolumesRemovesAnonymousOnes() async throws {
        let yaml = """
        name: shop
        services:
          web:
            image: nginx
            volumes: [/var/cache/nginx, data:/data]
        volumes:
          data:
        """
        let mock = MockRunner()
        _ = await ComposeRunner(runner: mock).down(try plan(yaml), removeVolumes: true)
        let name = VolumeCopyUp.anonymousVolumeName(container: "shop-web", path: "/var/cache/nginx")
        let executed = await mock.commands
        XCTAssertTrue(executed.contains(["volume", "delete", "shop-data"]))
        XCTAssertTrue(executed.contains(["volume", "delete", name]))

        let kept = MockRunner()
        _ = await ComposeRunner(runner: kept).down(try plan(yaml), removeVolumes: false)
        let volumeCommands = await kept.commands.filter { $0.first == "volume" }
        XCTAssertTrue(volumeCommands.isEmpty)
    }
}

final class RunArgumentsTests: XCTestCase {
    func testReadsImageAndVolumesFromPlannedArguments() {
        let run = RunArguments(["run", "--detach", "--name", "shop-db", "--label", "a=b", "--network", "shop-default",
                                "--env", "PGDATA=/x", "--volume", "shop-data:/var/lib/postgresql/data:ro",
                                "--volume", "./init:/docker-entrypoint-initdb.d", "-v", "/abs:/abs",
                                "--mount", "type=volume,target=/cache", "--mount", "type=volume,source=named,target=/n",
                                "--tmpfs", "/run", "--read-only", "--init", "postgres:16", "postgres", "-c", "fsync=off"])!
        XCTAssertEqual(run.image, "postgres:16")
        XCTAssertEqual(run.namedVolumes, [.init(name: "shop-data", target: "/var/lib/postgresql/data")])
        XCTAssertEqual(run.anonymousVolumes, [.init(valueIndex: 17, target: "/cache", readOnly: false)])
    }

    func testOptionWithEqualsTakesNoValue() {
        let run = RunArguments(["run", "--memory=512M", "--cpus=2", "alpine"])!
        XCTAssertEqual(run.image, "alpine")
    }

    func testNotARunOrNoImage() {
        XCTAssertNil(RunArguments(["volume", "create", "x"]))
        XCTAssertNil(RunArguments(["run", "--detach", "--name"]))
        XCTAssertNil(RunArguments(["run", "--name", "x"]))
    }
}
