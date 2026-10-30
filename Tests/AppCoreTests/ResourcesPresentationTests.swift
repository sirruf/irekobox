import XCTest
import ContainerKit
@testable import AppCore

final class ResourcesPresentationTests: XCTestCase {
    func testSubnetRanges() {
        XCTAssertEqual(Subnets.range("192.168.66.0/24"), .init(start: 0xC0A8_4200, end: 0xC0A8_42FF))
        XCTAssertEqual(Subnets.range("10.10.3.7/16"), .init(start: 0x0A0A_0000, end: 0x0A0A_FFFF), "host bits are masked")
        XCTAssertNil(Subnets.range("192.168.1.0"))
        XCTAssertNil(Subnets.range("300.1.1.0/24"))
        XCTAssertNil(Subnets.range("10.0.0.0/4"))
        XCTAssertTrue(Subnets.range("10.0.0.0/8")!.overlaps(Subnets.range("10.20.0.0/24")!))
        XCTAssertFalse(Subnets.range("192.168.66.0/24")!.overlaps(Subnets.range("192.168.67.0/24")!))
    }

    func testFreeSubnetSkipsTakenAndOverlapping() {
        XCTAssertEqual(Subnets.free(after: []), "192.168.64.0/24")
        XCTAssertEqual(Subnets.free(after: ["192.168.64.0/24", "192.168.65.0/24", "192.168.66.0/23"]), "192.168.68.0/24")
        XCTAssertEqual(Subnets.free(after: ["192.168.66.0/24", "192.168.68.0/24"]), "192.168.69.0/24", "above the highest, not in a gap")
    }

    func testImageReferenceSplit() {
        XCTAssertTrue(ImagesView.split("nginx:alpine") == ("nginx", "alpine"))
        XCTAssertTrue(ImagesView.split("localhost:5000/shop/api") == ("localhost:5000/shop/api", ""))
        XCTAssertTrue(ImagesView.split("node@sha256:abc") == ("node", ""))
    }
}

final class PushDestinationTests: XCTestCase {
    func testRegistryOfAReference() {
        XCTAssertEqual(PushDestination.registry(of: "ghcr.io/me/app:1"), "ghcr.io")
        XCTAssertEqual(PushDestination.registry(of: "localhost:5000/app"), "localhost:5000")
        XCTAssertEqual(PushDestination.registry(of: "me/app:1"), "docker.io")
        XCTAssertEqual(PushDestination.registry(of: "nginx:alpine"), "docker.io")
    }

    func testOfficialImagesGoUnderTheAccount() {
        let hub = RegistryLogin(hostname: "docker.io", username: "sam")
        XCTAssertEqual(PushDestination.suggestion(for: "docker.io/library/nginx:alpine", logins: [hub]), "docker.io/sam/nginx:alpine")
        XCTAssertEqual(PushDestination.suggestion(for: "docker.io/library/nginx:alpine", logins: []), "")
        XCTAssertEqual(PushDestination.suggestion(for: "ghcr.io/me/api:dev", logins: [hub]), "ghcr.io/me/api:dev")
    }

    func testProblems() {
        XCTAssertNotNil(PushDestination.problem(""))
        XCTAssertNotNil(PushDestination.problem("docker.io/library/nginx:alpine"))
        XCTAssertNotNil(PushDestination.problem("nginx:alpine"))
        XCTAssertNil(PushDestination.problem("docker.io/sam/nginx:alpine"))
        XCTAssertNil(PushDestination.problem("ghcr.io/me/api:dev"))
    }
}

final class VolumeHelperTests: XCTestCase {
    func testBackupMountsTheVolumeReadOnly() {
        let arguments = VolumeHelper.backupArguments(volume: "pgdata", folder: "/Users/me/Backups", file: "pgdata.tar.gz")
        XCTAssertEqual(arguments.prefix(2), ["run", "--rm"])
        XCTAssertTrue(arguments.contains("pgdata:/data:ro"))
        XCTAssertTrue(arguments.contains("/Users/me/Backups:/backup"))
        XCTAssertEqual(arguments.suffix(5), ["czf", "/backup/pgdata.tar.gz", "-C", "/data", "."])
    }

    func testBrowserIsLabelledAndRemovesItself() {
        let arguments = VolumeHelper.browseArguments(volume: "pgdata", name: VolumeHelper.browserName("pgdata"))
        XCTAssertTrue(arguments.contains("--rm"))
        XCTAssertTrue(arguments.contains("\(VolumeHelper.label)=browse"))
        XCTAssertEqual(VolumeHelper.browserName("my vol/x"), "irekobox-files-my-vol-x")
    }
}
