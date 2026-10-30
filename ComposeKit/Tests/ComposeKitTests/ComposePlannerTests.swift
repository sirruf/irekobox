import XCTest
@testable import ComposeKit

final class ComposePlannerTests: XCTestCase {

    let sample = """
    name: shop
    services:
      db:
        image: postgres:16
        environment:
          POSTGRES_PASSWORD: secret
          POSTGRES_DB: shop
        volumes:
          - db-data:/var/lib/postgresql/data
        networks:
          - backend
      web:
        build: ./web
        command: ["npm", "start"]
        ports:
          - "8080:3000"
          - "443:443/tcp"
        environment:
          - NODE_ENV=production
        depends_on:
          db:
            condition: service_healthy
        networks:
          - backend
        privileged: true
        restart: always
    networks:
      backend:
    volumes:
      db-data:
    """

    func parsePlan(profiles: Set<String> = []) throws -> ComposePlan {
        let parsed = try ComposeParser(environment: [:]).parse(sample)
        return try ComposePlanner().plan(parsed, activeProfiles: profiles)
    }

    func testProjectAndOrdering() throws {
        let plan = try parsePlan()
        XCTAssertEqual(plan.projectName, "shop")

        // db must come before web (web depends_on db).
        let runOrder = plan.steps.filter { $0.kind == .run }.compactMap(\.service)
        XCTAssertEqual(runOrder, ["db", "web"])
    }

    func testNetworkAndVolumeSteps() throws {
        let plan = try parsePlan()
        let networks = plan.steps.filter { $0.kind == .network }.map { $0.arguments }
        let volumes = plan.steps.filter { $0.kind == .volume }.map { $0.arguments }
        XCTAssertTrue(networks.contains(["network", "create", "shop-backend"]))
        XCTAssertTrue(volumes.contains(["volume", "create", "shop-db-data"]))
    }

    func testDbRunArguments() throws {
        let plan = try parsePlan()
        let db = try XCTUnwrap(plan.steps.first { $0.service == "db" && $0.kind == .run })
        XCTAssertEqual(db.containerName, "shop-db")
        XCTAssertTrue(db.arguments.contains("postgres:16"))
        XCTAssertTrue(adjacent(db.arguments, "--network", "shop-backend"))
        XCTAssertTrue(adjacent(db.arguments, "--env", "POSTGRES_PASSWORD=secret"))
        XCTAssertTrue(adjacent(db.arguments, "--volume", "shop-db-data:/var/lib/postgresql/data"))
    }

    func testWebBuildAndPortsAndCommand() throws {
        let plan = try parsePlan()
        // build step before run, tagged shop-web
        let build = try XCTUnwrap(plan.steps.first { $0.service == "web" && $0.kind == .build })
        XCTAssertTrue(adjacent(build.arguments, "--tag", "shop-web"))
        XCTAssertEqual(build.arguments.last, "./web")

        let web = try XCTUnwrap(plan.steps.first { $0.service == "web" && $0.kind == .run })
        XCTAssertTrue(web.arguments.contains("shop-web"))      // runs the built tag
        XCTAssertTrue(adjacent(web.arguments, "--publish", "8080:3000"))
        XCTAssertTrue(adjacent(web.arguments, "--publish", "443:443/tcp"))
        // command is trailing
        XCTAssertEqual(Array(web.arguments.suffix(2)), ["npm", "start"])
    }

    func testWarnings() throws {
        let plan = try parsePlan()
        // privileged → unsupported; restart → info
        XCTAssertTrue(plan.warnings.contains { $0.field == "privileged" && $0.severity == .unsupported })
        XCTAssertTrue(plan.warnings.contains { $0.field == "restart" && $0.severity == .info })
    }

    func testExtraRunLabelsInjected() throws {
        let yaml = "services:\n  web:\n    image: nginx\n"
        let parsed = try ComposeParser(environment: [:]).parse(yaml)
        let plan = try ComposePlanner().plan(parsed, projectName: "shop",
                                             extraRunLabels: ["com.irekobox.stack": "shop"])
        let run = try XCTUnwrap(plan.steps.first { $0.kind == .run })
        XCTAssertTrue(adjacent(run.arguments, "--label", "com.irekobox.stack=shop"))
        XCTAssertTrue(adjacent(run.arguments, "--label", "com.docker.compose.project=shop"))
        XCTAssertTrue(adjacent(run.arguments, "--label", "com.docker.compose.service=\(run.service!)"))
    }

    func testStringCommandIsShellSplit() throws {
        let yaml = """
        services:
          redis:
            image: redis:7-alpine
            command: redis-server --appendonly yes
        """
        let parsed = try ComposeParser(environment: [:]).parse(yaml)
        let plan = try ComposePlanner().plan(parsed, projectName: "p")
        let run = try XCTUnwrap(plan.steps.first { $0.service == "redis" && $0.kind == .run })
        // command must be three trailing args, not one literal blob.
        XCTAssertEqual(Array(run.arguments.suffix(3)), ["redis-server", "--appendonly", "yes"])
        XCTAssertFalse(run.arguments.contains("redis-server --appendonly yes"))
    }

    func testInterpolation() throws {
        let yaml = """
        services:
          app:
            image: nginx:${TAG:-latest}
        """
        let parsed = try ComposeParser(environment: [:]).parse(yaml)
        XCTAssertEqual(parsed.file.services["app"]?.image, "nginx:latest")

        let parsed2 = try ComposeParser(environment: ["TAG": "1.27"]).parse(yaml)
        XCTAssertEqual(parsed2.file.services["app"]?.image, "nginx:1.27")
    }

    func testCycleDetected() throws {
        let yaml = """
        services:
          a:
            image: x
            depends_on: [b]
          b:
            image: y
            depends_on: [a]
        """
        let parsed = try ComposeParser(environment: [:]).parse(yaml)
        XCTAssertThrowsError(try ComposePlanner().plan(parsed))
    }

    // Helper: is `value` immediately after `flag` in args?
    private func adjacent(_ args: [String], _ flag: String, _ value: String) -> Bool {
        for i in args.indices.dropLast() where args[i] == flag && args[i + 1] == value {
            return true
        }
        return false
    }

    func testHealthcheckBecomesTheAgentsLabel() throws {
        let yaml = """
        services:
          db:
            image: postgres:16
            healthcheck:
              test: ["CMD", "pg_isready", "-U", "app"]
              interval: 1m30s
              timeout: 500ms
              retries: 5
              start_period: 10s
          web:
            image: nginx
            healthcheck:
              test: curl -f http://localhost/ || exit 1
          off:
            image: nginx
            healthcheck:
              disable: true
        """
        let plan = try ComposePlanner().plan(try ComposeParser(environment: [:]).parse(yaml), projectName: "p")
        func label(_ service: String) throws -> String? {
            let run = try XCTUnwrap(plan.steps.first { $0.service == service && $0.kind == .run })
            return run.arguments.first { $0.hasPrefix("com.irekobox.docker.healthcheck=") }
        }
        XCTAssertEqual(try label("db"), #"com.irekobox.docker.healthcheck={"Interval":90000000000,"Retries":5,"StartPeriod":10000000000,"Test":["CMD","pg_isready","-U","app"],"Timeout":500000000}"#)
        XCTAssertEqual(try label("web"), #"com.irekobox.docker.healthcheck={"Test":["CMD-SHELL","curl -f http://localhost/ || exit 1"]}"#)
        XCTAssertNil(try label("off"))
        XCTAssertFalse(plan.warnings.contains { $0.message.contains("not run yet") })
    }

    func testLocalDomainNamesTheService() throws {
        let yaml = """
        services:
          web:
            image: nginx
        """
        let parsed = try ComposeParser(environment: [:]).parse(yaml)
        let named = try ComposePlanner().plan(parsed, projectName: "shop", localDomain: "test")
        let run = try XCTUnwrap(named.steps.first { $0.service == "web" && $0.kind == .run })
        XCTAssertTrue(run.arguments.contains { $0.hasSuffix(",alias=web.shop.test") }, "\(run.arguments)")
        let plain = try ComposePlanner().plan(parsed, projectName: "shop")
        XCTAssertFalse(try XCTUnwrap(plain.steps.first { $0.kind == .run }).arguments.contains { $0.contains("alias=") })
    }
}
