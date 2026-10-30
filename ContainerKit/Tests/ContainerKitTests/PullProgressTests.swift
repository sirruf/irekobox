import XCTest
@testable import ContainerKit

/// Lines captured from `container image pull --progress plain` (1.6.1).
final class PullProgressTests: XCTestCase {

    func testFetchingWithPercentage() throws {
        let p = try XCTUnwrap(PullProgress.parse("[1/2] Fetching image 49% (35 of 52 blobs, 8.2/16.7 MB, 3.8 MB/s) [6s]"))
        XCTAssertEqual(p.step, 1)
        XCTAssertEqual(p.totalSteps, 2)
        XCTAssertEqual(p.phase, "Fetching image")
        XCTAssertEqual(p.fraction, 0.49)
        XCTAssertEqual(p.detail, "8.2/16.7 MB, 3.8 MB/s")
        XCTAssertEqual(p.overall ?? 0, 0.245, accuracy: 0.0001)
    }

    func testPhasesWithoutPercentage() throws {
        let start = try XCTUnwrap(PullProgress.parse("[1/2] Fetching image [0s]"))
        XCTAssertNil(start.fraction)
        XCTAssertEqual(start.overall, 0)

        let blobs = try XCTUnwrap(PullProgress.parse("[1/2] Fetching image (7 of 18 blobs) [2s]"))
        XCTAssertEqual(blobs.detail, "7 of 18 blobs", "nothing but the count: keep it")

        let unpack = try XCTUnwrap(PullProgress.parse("[2/2] Unpacking image for platform linux/arm64 100% (448 entries, 4.0 MB) [3s]"))
        XCTAssertEqual(unpack.phase, "Unpacking image for platform linux/arm64")
        XCTAssertEqual(unpack.overall, 1)
        XCTAssertEqual(unpack.detail, "4.0 MB")
    }

    func testOtherLinesAreIgnored() {
        XCTAssertNil(PullProgress.parse("Error: unauthorized"))
        XCTAssertNil(PullProgress.parse(""))
    }
}
