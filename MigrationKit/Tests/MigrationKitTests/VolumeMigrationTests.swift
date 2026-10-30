import XCTest
@testable import MigrationKit

final class VolumeMigrationTests: XCTestCase {
    let m = VolumeMigration()

    func testClassify() {
        XCTAssertEqual(m.classify("db-data"), .named)
        XCTAssertEqual(m.classify("/var/lib/x"), .bind)
        XCTAssertEqual(m.classify("./data"), .bind)
        XCTAssertEqual(m.classify("../shared"), .bind)
        XCTAssertEqual(m.classify("~/stuff"), .bind)
    }

    func testBindMountNeedsNoCopy() {
        let cmd = m.bindMount(hostPath: "/Users/me/data", target: "/data")
        XCTAssertEqual(cmd.tool, .container)
        XCTAssertEqual(cmd.arguments, ["run", "-v", "/Users/me/data:/data"])
    }

    func testCopyNamedPipeline() {
        let steps = m.copyNamed(dockerVolume: "pgdata",
                                containerVolume: "shop-pgdata",
                                tarDirectory: "/tmp/cz",
                                tarName: "pgdata.tar")
        XCTAssertEqual(steps.count, 3)

        // 1) docker export (read-only source)
        XCTAssertEqual(steps[0].tool, .docker)
        XCTAssertTrue(steps[0].arguments.contains("pgdata:/from:ro"))
        XCTAssertTrue(steps[0].arguments.contains("/tmp/cz:/backup"))
        XCTAssertEqual(Array(steps[0].arguments.suffix(6)), ["tar", "cf", "/backup/pgdata.tar", "-C", "/from", "."])

        // 2) create container volume
        XCTAssertEqual(steps[1].tool, .container)
        XCTAssertEqual(steps[1].arguments, ["volume", "create", "shop-pgdata"])

        // 3) container import
        XCTAssertEqual(steps[2].tool, .container)
        XCTAssertTrue(steps[2].arguments.contains("shop-pgdata:/to"))
        XCTAssertEqual(Array(steps[2].arguments.suffix(5)), ["tar", "xf", "/backup/pgdata.tar", "-C", "/to"])
    }
}
