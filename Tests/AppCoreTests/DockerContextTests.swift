import XCTest
@testable import AppCore

final class DockerContextTests: XCTestCase {
    func testBuilderLoadsWhatItBuilds() {
        XCTAssertEqual(DockerContext.builderArguments(socketPath: "/s/docker.sock"), [
            "buildx", "create", "--name", "irekobox", "--driver", "docker-container",
            "--driver-opt", "default-load=true", "unix:///s/docker.sock",
        ])
    }

    func testBuildxFolderFollowsTheEnvironment() {
        XCTAssertEqual(DockerContext.buildxFolder(["BUILDX_CONFIG": "/b", "DOCKER_CONFIG": "/d"]).path, "/b")
        XCTAssertEqual(DockerContext.buildxFolder(["DOCKER_CONFIG": "/d"]).path, "/d/buildx")
        XCTAssertTrue(DockerContext.buildxFolder([:]).path.hasSuffix("/.docker/buildx"))
    }

    func testPluginOnlyConfigKeepsPluginFoldersAndNothingElse() throws {
        let real = Data(#"{"currentContext":"irekobox","auths":{"x":{"auth":"secret"}},"cliPluginsExtraDirs":["/opt/plugins"]}"#.utf8)
        let data = try DockerContext.pluginOnlyConfig(from: real, dockerFolder: URL(filePath: "/d"))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Array(config.keys), ["cliPluginsExtraDirs"])
        XCTAssertEqual(config["cliPluginsExtraDirs"] as? [String], ["/opt/plugins", "/d/cli-plugins"])
    }

    func testPluginOnlyConfigWithoutARealConfig() throws {
        let data = try DockerContext.pluginOnlyConfig(from: nil, dockerFolder: URL(filePath: "/d"))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(config["cliPluginsExtraDirs"] as? [String], ["/d/cli-plugins"])
    }
}
