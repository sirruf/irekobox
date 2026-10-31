import XCTest
@testable import ContainerKit

final class InsecureRegistriesTests: XCTestCase {
    func testLoopbackIsAlwaysInsecure() {
        for host in ["localhost", "localhost:5000", "127.0.0.1:5055", "[::1]:5000"] {
            XCTAssertTrue(InsecureRegistries.isInsecure(host: host, listed: []), host)
        }
        XCTAssertFalse(InsecureRegistries.isInsecure(host: "registry.example.com", listed: []))
    }

    func testListedRegistriesMatchByHostOrHostAndPort() {
        XCTAssertTrue(InsecureRegistries.isInsecure(host: "server:5000", listed: ["server:5000"]))
        XCTAssertTrue(InsecureRegistries.isInsecure(host: "server:5000", listed: ["server"]))
        XCTAssertFalse(InsecureRegistries.isInsecure(host: "server:6000", listed: ["server:5000"]))
    }

    func testSchemeForAnImageFollowsItsRegistry() {
        XCTAssertEqual(InsecureRegistries.schemeArguments(reference: "server:5000/team/app:2", listed: ["server:5000"]),
                       ["--scheme", "http"])
        XCTAssertEqual(InsecureRegistries.schemeArguments(reference: "alpine", listed: ["server:5000"]), [])
    }

    func testReadsTheDaemonConfig() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "daemon-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"experimental":false,"insecure-registries":["server:5000"]}"#.utf8).write(to: file)
        XCTAssertEqual(InsecureRegistries.listed(in: file), ["server:5000"])
        XCTAssertEqual(InsecureRegistries.listed(in: file.appending(path: "missing")), [])
    }
}
