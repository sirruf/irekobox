import XCTest
@testable import AppCore
import ContainerKit

final class RunConfigurationTests: XCTestCase {

    func testArguments() {
        var config = RunConfiguration()
        config.image = "nginx:alpine"
        config.name = "site"
        config.ports = [.init(host: "8080", container: "80"), .init(host: "5353", container: "53", proto: .udp)]
        config.mounts = [.init(source: "~/code/site", target: "/usr/share/nginx/html", readOnly: true),
                         .init(source: "cache", target: "/cache")]
        config.variables = [.init(key: "GREETING", value: "hello world")]
        config.cpus = 2
        config.memoryMiB = 512
        config.amd64 = true
        config.network = "shop_default"
        config.removeWhenStopped = true
        config.command = "nginx -g 'daemon off;'"

        XCTAssertEqual(config.arguments(homeDirectory: "/Users/me"), [
            "--detach", "--name", "site",
            "--publish", "8080:80", "--publish", "5353:53/udp",
            "--volume", "/Users/me/code/site:/usr/share/nginx/html:ro", "--volume", "cache:/cache",
            "--env", "GREETING=hello world",
            "--cpus", "2", "--memory", "512M", "--platform", "linux/amd64",
            "--network", "shop_default", "--rm",
            "nginx:alpine", "nginx", "-g", "daemon off;",
        ])
        XCTAssertTrue(config.commandLine().hasPrefix("container run --detach --name site"))
        XCTAssertTrue(config.commandLine().contains("--env 'GREETING=hello world'"))
    }

    func testMinimalArguments() {
        var config = RunConfiguration()
        config.image = "alpine"
        config.ports = [.init()]   // an empty row is ignored
        XCTAssertEqual(config.arguments(), ["--detach", "alpine"])
        XCTAssertTrue(config.issues(existingNames: [], usedHostPorts: []).isEmpty)
    }

    func testImageAndNameChecks() {
        var config = RunConfiguration()
        XCTAssertEqual(config.issues(existingNames: [], usedHostPorts: []).map(\.field), [.image])
        config.image = "alpine"
        config.name = "-bad name"
        XCTAssertEqual(config.issues(existingNames: [], usedHostPorts: []).first?.field, .name)
        config.name = "web"
        XCTAssertEqual(config.issues(existingNames: ["web"], usedHostPorts: []).first?.message,
                       "A container named “web” already exists.")
    }

    func testPortChecksAndSuggestions() throws {
        var config = RunConfiguration()
        config.image = "alpine"
        let airplay = RunConfiguration.Port(host: "5000", container: "5000")
        let taken = RunConfiguration.Port(host: "8080", container: "80")
        let invalid = RunConfiguration.Port(host: "99999", container: "80")
        config.ports = [airplay, taken, invalid]
        let issues = config.issues(existingNames: [], usedHostPorts: [8080, 8130])

        let airplayIssue = try XCTUnwrap(issues.first { $0.field == .port(airplay.id) })
        XCTAssertEqual(airplayIssue.severity, .warning)
        XCTAssertEqual(airplayIssue.suggestion, .hostPort(portID: airplay.id, value: "5050"))

        let takenIssue = try XCTUnwrap(issues.first { $0.field == .port(taken.id) })
        XCTAssertEqual(takenIssue.severity, .error)
        XCTAssertEqual(takenIssue.suggestion, .hostPort(portID: taken.id, value: "8131"), "skips used 8130")

        XCTAssertEqual(issues.first { $0.field == .port(invalid.id) }?.message, "Host port must be 1–65535.")
    }

    func testDuplicateHostPort() {
        var config = RunConfiguration()
        config.image = "alpine"
        config.ports = [.init(host: "8080", container: "80"), .init(host: "8080", container: "81")]
        XCTAssertTrue(config.issues(existingNames: [], usedHostPorts: []).contains { $0.message == "Host port 8080 is published twice." })
        // The same number over UDP is a different port.
        config.ports[1].proto = .udp
        XCTAssertTrue(config.issues(existingNames: [], usedHostPorts: []).isEmpty)
    }

    func testMountAndVariableChecks() {
        var config = RunConfiguration()
        config.image = "alpine"
        config.mounts = [.init(source: "relative/dir", target: "/data"), .init(source: "/abs", target: "data")]
        config.variables = [.init(key: "1BAD", value: "x")]
        let messages = config.issues(existingNames: [], usedHostPorts: []).map(\.message)
        XCTAssertTrue(messages.contains("Use an absolute folder path, ~/…, or a volume name."))
        XCTAssertTrue(messages.contains("The path in the container must start with “/”."))
        XCTAssertTrue(messages.contains { $0.hasPrefix("Variable names use") })
    }

    func testEnvFileParsing() {
        let variables = RunConfiguration.parseEnvFile("""
        # comment
        NODE_ENV=development
        export API_URL="http://localhost:3000"
        QUOTED='single quoted'

        EMPTY=
        not a variable
        """)
        XCTAssertEqual(variables.map(\.key), ["NODE_ENV", "API_URL", "QUOTED", "EMPTY"])
        XCTAssertEqual(variables.map(\.value), ["development", "http://localhost:3000", "single quoted", ""])
    }
}

@MainActor
final class RunSheetHintsTests: XCTestCase {
    /// Choosing an image fills in its ports (a free host port), a volume for
    /// its data and the variables it needs; Run waits for the password.
    func testImageHintsFillTheForm() async throws {
        let registry = RegistryClient { request in
            let url = request.url!
            func ok(_ body: String) -> (Data, HTTPURLResponse) {
                (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            switch url.path {
            case "/v2/library/postgres/manifests/17": return ok(#"{"config":{"digest":"sha256:cfg"}}"#)
            case "/v2/library/postgres/blobs/sha256:cfg":
                return ok(#"{"config":{"ExposedPorts":{"5432/tcp":{}},"Volumes":{"/var/lib/postgresql/data":{}}}}"#)
            default: return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
        }
        let model = RunSheetModel(image: "postgres:17")
        model.usedHostPorts = [5432]
        await model.loadHints(for: "postgres:17", engine: CLIEngine(cli: MockCLI(), stream: CLIStream()),
                              local: [], registry: registry)
        XCTAssertEqual(model.config.ports.map(\.host), ["5433"])
        XCTAssertEqual(model.config.ports.map(\.container), ["5432"])
        XCTAssertEqual(model.config.mounts.map(\.source), ["postgres-data"])
        XCTAssertEqual(model.config.mounts.map(\.target), ["/var/lib/postgresql/data"])
        XCTAssertEqual(model.config.variables.map(\.key), ["POSTGRES_PASSWORD"])
        XCTAssertFalse(model.canRun)
        model.config.variables[0].value = "secret"
        XCTAssertTrue(model.canRun)
    }
}

final class TrustedBinaryTests: XCTestCase {
    /// Only Apple's signed `container`, in a root-owned folder, may run as root.
    func testOnlyAppleContainerIsTrusted() throws {
        XCTAssertFalse(ContainerInstaller.isTrustedBinary(at: "/bin/ls"), "Apple-signed, but not the container CLI")
        let copy = FileManager.default.temporaryDirectory.appending(path: "ib-fake-container-\(UUID().uuidString)")
        try Data("#!/bin/sh\n".utf8).write(to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        XCTAssertFalse(ContainerInstaller.isTrustedBinary(at: copy.path))
        XCTAssertFalse(ContainerInstaller.isTrustedBinary(at: "/usr/local/bin/con'tainer"))
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/usr/local/bin/container"), "container not installed")
        XCTAssertTrue(ContainerInstaller.isTrustedBinary(at: "/usr/local/bin/container"))
    }
}
