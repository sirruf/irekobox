import XCTest
@testable import MigrationKit

final class DockerImageImportTests: XCTestCase {
    func testPlanSaveThenLoad() {
        let steps = DockerImageImport().plan(image: "nginx:latest", tarPath: "/tmp/x.tar")
        XCTAssertEqual(steps.count, 2)

        XCTAssertEqual(steps[0].tool, .docker)
        XCTAssertEqual(steps[0].arguments, ["save", "nginx:latest", "-o", "/tmp/x.tar"])

        XCTAssertEqual(steps[1].tool, .container)
        XCTAssertEqual(steps[1].arguments, ["image", "load", "-i", "/tmp/x.tar"])
    }
}
