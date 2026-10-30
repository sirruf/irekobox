import XCTest
@testable import MigrationKit

final class DockerRunTranslatorTests: XCTestCase {
    let t = DockerRunTranslator()

    func testBasicFlags() throws {
        let r = try t.translate("docker run -d --name web -p 8080:80 -e FOO=bar nginx:latest")
        XCTAssertEqual(r.image, "nginx:latest")
        XCTAssertTrue(adjacent(r.arguments, "--name", "web"))
        XCTAssertTrue(adjacent(r.arguments, "--publish", "8080:80"))
        XCTAssertTrue(adjacent(r.arguments, "--env", "FOO=bar"))
        XCTAssertTrue(r.arguments.contains("--detach"))
        XCTAssertEqual(r.arguments.first, "run")
        XCTAssertEqual(r.arguments.last, "nginx:latest")
    }

    func testCombinedShortFlagsAndCommand() throws {
        let r = try t.translate("docker run -it --rm alpine sh -c \"echo hi\"")
        XCTAssertTrue(r.arguments.contains("--interactive"))
        XCTAssertTrue(r.arguments.contains("--tty"))
        XCTAssertTrue(r.arguments.contains("--rm"))
        XCTAssertEqual(r.image, "alpine")
        // command after the image, with the quoted segment intact
        XCTAssertEqual(Array(r.arguments.suffix(3)), ["sh", "-c", "echo hi"])
    }

    func testShortFlagWithAttachedValue() throws {
        let r = try t.translate("docker run -p8080:80 -eK=V nginx")
        XCTAssertTrue(adjacent(r.arguments, "--publish", "8080:80"))
        XCTAssertTrue(adjacent(r.arguments, "--env", "K=V"))
    }

    func testEqualsForm() throws {
        let r = try t.translate("docker run --name=web --env=A=1 busybox")
        XCTAssertTrue(adjacent(r.arguments, "--name", "web"))
        XCTAssertTrue(adjacent(r.arguments, "--env", "A=1"))
    }

    func testContainerRunPrefixAndRelativeVolume() throws {
        let r = try t.translate("docker container run -v ./data:/data busybox")
        XCTAssertEqual(r.image, "busybox")
        XCTAssertTrue(adjacent(r.arguments, "--volume", "./data:/data"))
    }

    func testUnsupportedAndInfoWarnings() throws {
        let r = try t.translate("docker run --privileged --restart always -h myhost nginx")
        XCTAssertFalse(r.arguments.contains("--privileged"))
        XCTAssertTrue(r.warnings.contains { $0.flag == "privileged" && $0.severity == .unsupported })
        XCTAssertTrue(r.warnings.contains { $0.flag == "restart" && $0.severity == .info })
        XCTAssertTrue(r.warnings.contains { $0.flag == "hostname" && $0.severity == .partial })
    }

    func testNoImageThrows() {
        XCTAssertThrowsError(try t.translate("docker run -d --rm"))
    }

    private func adjacent(_ args: [String], _ flag: String, _ value: String) -> Bool {
        for i in args.indices.dropLast() where args[i] == flag && args[i + 1] == value { return true }
        return false
    }
}
