import XCTest
import ContainerKit
@testable import AppCore

final class ContainerListTests: XCTestCase {

    private func container(_ id: String, state: String = "running", image: String = "alpine",
                           labels: [String: String] = [:], port: Int? = nil,
                           env: [String] = []) -> Container {
        let labelJSON = labels.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
        let portJSON = port.map { #","publishedPorts":[{"containerPort":80,"hostPort":\#($0),"proto":"tcp"}]"# } ?? ""
        let envJSON = env.map { "\"\($0)\"" }.joined(separator: ",")
        let json = """
        {"id":"\(id)","status":{"state":"\(state)","networks":[]},"configuration":{"id":"\(id)",\
        "image":{"reference":"\(image)","descriptor":{"digest":"d","mediaType":"m","size":1}},\
        "resources":{"cpus":1,"memoryInBytes":1},"platform":{"architecture":"arm64","os":"linux"},"networks":[],\
        "initProcess":{"executable":"sh","arguments":[],"workingDirectory":"/","environment":[\(envJSON)]},\
        "labels":{\(labelJSON)},"creationDate":"2026-10-25T00:00:00Z","readOnly":false,"runtimeHandler":"r",\
        "rosetta":false\(portJSON)}}
        """
        return try! JSONDecoder().decode(Container.self, from: Data(json.utf8))
    }

    func testFilterBySearchStateAndSystem() {
        let all = [
            container("api", image: "node:22", labels: [StackLabel.key: "shop"], port: 3000),
            container("db", state: "stopped", image: "postgres:16", labels: [StackLabel.key: "shop"]),
            container("buildkit", labels: ["com.apple.container.resource.role": "builder"]),
        ]
        XCTAssertEqual(ContainerList.filter(all, search: "", state: .all, includeSystem: false).map(\.id), ["api", "db"])
        XCTAssertEqual(ContainerList.filter(all, search: "", state: .all, includeSystem: true).count, 3)
        XCTAssertEqual(ContainerList.filter(all, search: "", state: .running, includeSystem: false).map(\.id), ["api"])
        XCTAssertEqual(ContainerList.filter(all, search: "", state: .stopped, includeSystem: false).map(\.id), ["db"])
        XCTAssertEqual(ContainerList.filter(all, search: "POSTGRES", state: .all, includeSystem: false).map(\.id), ["db"])
        XCTAssertEqual(ContainerList.filter(all, search: ":3000", state: .all, includeSystem: false).map(\.id), ["api"])
        XCTAssertEqual(ContainerList.filter(all, search: "shop", state: .all, includeSystem: false).count, 2)
    }

    func testGroupingPutsProjectsFirst() {
        let groups = ContainerList.group([
            container("redis-dev"),
            container("worker", labels: ["com.docker.compose.project": "shop"]),
            container("api", labels: [StackLabel.key: "shop"]),
            container("web", labels: [StackLabel.key: "blog"]),
        ])
        XCTAssertEqual(groups.map(\.title), ["blog", "shop", "Standalone"])
        XCTAssertEqual(groups[1].containers.map(\.id), ["worker", "api"])
        XCTAssertEqual(groups[1].running, 2)
    }

    func testSecretsAreMasked() {
        XCTAssertEqual(ContainerList.maskedEnvironment("POSTGRES_PASSWORD=hunter2"), "POSTGRES_PASSWORD=••••••")
        XCTAssertEqual(ContainerList.maskedEnvironment("GITHUB_TOKEN=abc"), "GITHUB_TOKEN=••••••")
        XCTAssertEqual(ContainerList.maskedEnvironment("DATABASE_URL=postgres://shop:s3cret@db:5432/shop"),
                       "DATABASE_URL=postgres://shop:••••••@db:5432/shop")
        XCTAssertEqual(ContainerList.maskedEnvironment("REDIS_URL=redis://cache:6379"), "REDIS_URL=redis://cache:6379")
        XCTAssertEqual(ContainerList.maskedEnvironment("NODE_ENV=development"), "NODE_ENV=development")
        XCTAssertEqual(ContainerList.maskedEnvironment("EMPTY_SECRET="), "EMPTY_SECRET=")
    }

    func testRunCommandIsShellSafe() {
        let c = container("web", image: "nginx:alpine", port: 8080, env: ["GREETING=hello world"])
        let command = ContainerList.runCommand(c)
        XCTAssertTrue(command.hasPrefix("container run --detach --name web"), command)
        XCTAssertTrue(command.contains("--env 'GREETING=hello world'"), command)
        XCTAssertTrue(command.contains("--publish 8080:80"), command)
        XCTAssertEqual(ContainerList.shellQuoted("it's"), "'it'\\''s'")
    }
}
