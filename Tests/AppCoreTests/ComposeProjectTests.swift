import XCTest
import ContainerKit
import ComposeKit
@testable import AppCore

final class ComposeProjectTests: XCTestCase {
    private func container(_ id: String, state: String = "running", labels: [String: String] = [:],
                           port: Int? = nil) -> Container {
        let labelJSON = labels.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
        let portJSON = port.map { #","publishedPorts":[{"containerPort":80,"hostPort":\#($0),"proto":"tcp"}]"# } ?? ""
        let json = """
        {"id":"\(id)","status":{"state":"\(state)","networks":[]},"configuration":{"id":"\(id)",\
        "image":{"reference":"docker.io/library/nginx:latest","descriptor":{"digest":"d","mediaType":"m","size":1}},\
        "resources":{"cpus":1,"memoryInBytes":1},"platform":{"architecture":"arm64","os":"linux"},"networks":[],\
        "initProcess":{"executable":"sh","arguments":[],"workingDirectory":"/","environment":[]},\
        "labels":{\(labelJSON)},"creationDate":"2026-10-25T00:00:00Z","readOnly":false,"runtimeHandler":"r",\
        "rosetta":false\(portJSON)}}
        """
        return try! JSONDecoder().decode(Container.self, from: Data(json.utf8))
    }

    /// Added projects come first; others are found by Docker Compose labels,
    /// with their folder and files from those labels.
    func testFindsProjectsStartedElsewhere() {
        let entry = StackEntry(name: "shop", composePath: "/p/shop/compose.yaml")
        let projects = ComposeProject.all(entries: [entry], containers: [
            container("shop-web", labels: [StackLabel.key: "shop"]),
            container("blog-db-1", state: "stopped", labels: [
                "com.docker.compose.project": "blog", "com.docker.compose.service": "db",
                ComposeProject.workingDirLabel: "/p/blog",
                ComposeProject.configFilesLabel: "/p/blog/compose.yaml,/p/blog/compose.override.yaml"]),
            container("loner"),
        ])
        XCTAssertEqual(projects.map(\.name), ["shop", "blog"])
        XCTAssertEqual(projects[0].directory, "/p/shop")
        XCTAssertEqual(projects[0].summary, .running)
        XCTAssertFalse(projects[1].isManagedHere)
        XCTAssertEqual(projects[1].directory, "/p/blog")
        XCTAssertEqual(projects[1].configFiles, ["/p/blog/compose.yaml", "/p/blog/compose.override.yaml"])
        XCTAssertEqual(projects[1].summary, .stopped)
    }

    /// Services come from the file and pick up their containers by label or
    /// by name; ports are the live ones once a container exists.
    func testServicesMergeFileAndContainers() throws {
        let yaml = """
        services:
          web:
            image: nginx
            ports: ["8080:80"]
            depends_on: [api]
          api:
            image: node
            ports: ["3000:3000"]
            depends_on: [db]
          db:
            image: postgres
            volumes: ["data:/var/lib/postgresql/data", "./init:/docker-entrypoint-initdb.d"]
        volumes:
          data:
        """
        let file = try ComposeParser(environment: [:]).parse(yaml).file
        let project = ComposeProject(name: "shop", entry: nil, directory: nil, configFiles: [], containers: [
            container("shop-web", labels: ["com.docker.compose.service": "web"], port: 8080),
            container("shop-api", state: "stopped"),
        ])
        let services = project.services(file: file)
        XCTAssertEqual(services.map(\.name), ["api", "db", "web"])
        let byName = Dictionary(uniqueKeysWithValues: services.map { ($0.name, $0) })
        XCTAssertEqual(byName["web"]?.tone, .positive)
        XCTAssertEqual(byName["api"]?.containers.map(\.id), ["shop-api"])
        XCTAssertEqual(byName["db"]?.stateLabel, "Not created")
        XCTAssertEqual(byName["web"]?.access.map(\.title), ["localhost:8080"])
        XCTAssertEqual(byName["api"]?.access, [], "an existing container publishes nothing: no planned ports")
        XCTAssertEqual(byName["db"]?.mounts.map(\.kind), [.volume, .folder])
        XCTAssertEqual(byName["db"]?.mounts.map(\.title), ["data", "init"])

        // The map: what you open first, then what it needs.
        XCTAssertEqual(ComposeTopology.rows(services), [["web"], ["api"], ["db"]])
    }

    func testTopologyHandlesSiblingsAndCycles() throws {
        let yaml = """
        services:
          web: {image: a, depends_on: [db, cache]}
          worker: {image: a, depends_on: [db]}
          db: {image: a}
          cache: {image: a}
          x: {image: a, depends_on: [y]}
          y: {image: a, depends_on: [x]}
        """
        let file = try ComposeParser(environment: [:]).parse(yaml).file
        let services = ComposeProject(name: "p", entry: nil, directory: nil, configFiles: [], containers: [])
            .services(file: file)
        let columns = ComposeTopology.rows(services)
        XCTAssertTrue(columns.first!.contains("web") && columns.first!.contains("worker"))
        XCTAssertTrue(columns[1].contains("db") && columns[1].contains("cache"))
        XCTAssertEqual(Set(columns.joined()), ["web", "worker", "db", "cache", "x", "y"], "a cycle still places every service")
    }

    /// Services with published ports go in the top row, whatever depends on
    /// them; the rest below, by what needs them.
    func testPublishedServicesComeFirst() throws {
        let yaml = """
        services:
          worker: {image: a, depends_on: [api]}
          api: {image: a, depends_on: [db]}
          cache: {image: a}
          db: {image: a}
          admin: {image: a, depends_on: [db]}
        """
        let file = try ComposeParser(environment: [:]).parse(yaml).file
        let services = ComposeProject(name: "p", entry: nil, directory: nil, configFiles: [], containers: [])
            .services(file: file)
        XCTAssertEqual(ComposeTopology.rows(services, top: ["api", "admin"]),
                       [["admin", "api"], ["cache", "db", "worker"]])
    }

    /// Placed cards keep their spots; new ones go in a row below them.
    func testSpotsSavedForNarrowerCardsNoLongerOverlap() {
        // Saved when cards were 210 wide; now web is 260 wide and would cover cache.
        let sizes = ["web": CGSize(width: 260, height: 120), "cache": CGSize(width: 210, height: 120)]
        let spots = MapPlacement.place(["web", "cache"],
                                       placed: ["web": CGPoint(x: 0, y: 0), "cache": CGPoint(x: 226, y: 0)],
                                       sizes: sizes)
        XCTAssertEqual(spots["web"], CGPoint(x: 0, y: 0))
        XCTAssertEqual(spots["cache"], CGPoint(x: 260 + MapPlacement.gap, y: 0))
        // Cards apart stay where they were put.
        let apart = MapPlacement.place(["web", "cache"],
                                       placed: ["web": CGPoint(x: 0, y: 0), "cache": CGPoint(x: 400, y: 300)],
                                       sizes: sizes)
        XCTAssertEqual(apart["cache"], CGPoint(x: 400, y: 300))
    }

    func testPlacementKeepsSpotsAndAddsBelow() {
        let sizes = ["web": CGSize(width: 200, height: 100), "db": CGSize(width: 200, height: 150)]
        let spots = MapPlacement.place(["web", "db", "cache", "queue"],
                                       placed: ["web": CGPoint(x: 400, y: 0), "db": CGPoint(x: 0, y: 80), "gone": .zero],
                                       sizes: sizes)
        XCTAssertEqual(spots["web"], CGPoint(x: 400, y: 0))
        XCTAssertEqual(spots["db"], CGPoint(x: 0, y: 80))
        XCTAssertNil(spots["gone"], "a service no longer in the project is left out")
        XCTAssertEqual(spots["cache"], CGPoint(x: 0, y: 80 + 150 + 56))
        XCTAssertEqual(spots["queue"], CGPoint(x: 210 + 16, y: 80 + 150 + 56))
        XCTAssertEqual(MapPlacement.extent(spots, sizes: sizes).width, 600)
    }

    /// Cards are ordered under what they're linked to, so lines don't cross.
    func testOrderUncrossesLinks() {
        let rows = [["a", "b"], ["y", "x"]]
        XCTAssertEqual(MapPlacement.order(rows, links: [("a", "x"), ("b", "y")]), [["a", "b"], ["x", "y"]])
    }

    /// Arranged rows are centered and stacked with a gap.
    func testArrangeCentersRows() {
        let sizes = ["a": CGSize(width: 200, height: 100), "b": CGSize(width: 200, height: 120),
                     "c": CGSize(width: 200, height: 80)]
        let spots = MapPlacement.arrange([["a", "b"], ["c"]], sizes: sizes, width: 1000)
        XCTAssertEqual(spots["a"], CGPoint(x: 284, y: 0))
        XCTAssertEqual(spots["b"], CGPoint(x: 516, y: 0))
        XCTAssertEqual(spots["c"], CGPoint(x: 400, y: 120 + 56))
    }

    /// Only services whose settings changed are recreated; gone ones removed.
    @MainActor
    func testChangesCompareSettingsHashes() {
        let old = ComposeViewModel.stamped(ComposePlan(projectName: "shop", steps: [
            PlanStep(kind: .run, service: "web", containerName: "shop-web", arguments: ["run", "--name", "shop-web", "nginx"]),
            PlanStep(kind: .run, service: "db", containerName: "shop-db", arguments: ["run", "--name", "shop-db", "postgres:16"]),
        ], warnings: []))
        func hash(_ service: String) -> String {
            let step = old.steps.first { $0.service == service }!
            return String(step.arguments[2].split(separator: "=").last!)
        }
        XCTAssertEqual(old.steps[0].arguments.prefix(3),
                       ["run", "--label", "\(ComposeViewModel.configHashLabel)=\(hash("web"))"])
        let existing = [
            container("shop-web", labels: [ComposeViewModel.configHashLabel: hash("web")]),
            container("shop-db", labels: [ComposeViewModel.configHashLabel: hash("db")]),
            container("shop-worker"),
        ]
        let edited = ComposeViewModel.stamped(ComposePlan(projectName: "shop", steps: [
            PlanStep(kind: .run, service: "web", containerName: "shop-web", arguments: ["run", "--name", "shop-web", "nginx"]),
            PlanStep(kind: .run, service: "db", containerName: "shop-db", arguments: ["run", "--name", "shop-db", "postgres:17"]),
            PlanStep(kind: .run, service: "cache", containerName: "shop-cache", arguments: ["run", "redis"]),
        ], warnings: []))
        XCTAssertEqual(ComposeViewModel.changes(edited, existing: existing), [
            .keep(service: "web"), .recreate(service: "db", container: "shop-db"),
            .add(service: "cache"), .remove(container: "shop-worker"),
        ])
    }
}

final class ComposeTemplateTests: XCTestCase {
    func testEveryTemplatePlans() throws {
        for template in ComposeTemplate.all {
            let parsed = try ComposeParser().parse(template.yaml)
            let plan = try ComposePlanner().plan(parsed, projectName: template.id)
            XCTAssertFalse(plan.steps.filter { $0.kind == .run }.isEmpty, "\(template.id) runs something")
        }
    }
}
