import XCTest
@testable import ContainerKit

final class VolumeCopyUpTests: XCTestCase {
    func testScriptRemovesLostAndFoundThenCopiesKeepingOwnerAndMode() {
        let script = VolumeCopyUp.script(sourcePath: "/var/lib/postgresql/data")
        let lines = script.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("rmdir /.irekobox-copyup/lost+found"))
        XCTAssertTrue(lines[1].contains("s='/var/lib/postgresql/data'"))
        XCTAssertTrue(lines[1].contains("|| exit 0"), "an image without the folder leaves the volume empty")
        XCTAssertTrue(script.contains("cp -a \"$s\"/. /.irekobox-copyup/"))
        XCTAssertTrue(script.contains("chown \"$(stat -c %u:%g \"$s\")\""))
        XCTAssertTrue(script.contains("chmod \"$(stat -c %a \"$s\")\""))
    }

    func testQuotingSurvivesApostrophes() {
        XCTAssertEqual(VolumeCopyUp.shellQuote("/it's here"), #"'/it'\''s here'"#)
    }

    func testHelperRunsTheImageShellAsRootWithTheVolume() {
        let arguments = VolumeCopyUp.helperArguments(name: "db-copyup-0", volume: "shop-data",
                                                     image: "postgres:16", sourcePath: "/data")
        XCTAssertEqual(Array(arguments.prefix(8)), ["--name", "db-copyup-0", "--entrypoint", "/bin/sh", "--user", "0",
                                                    "--volume", "shop-data:/.irekobox-copyup"])
        XCTAssertEqual(arguments[8], "postgres:16")
        XCTAssertEqual(arguments[9], "-c")
        XCTAssertEqual(arguments[10], VolumeCopyUp.script(sourcePath: "/data"))
    }

    func testAnonymousVolumeNamesAreStableAndDistinct() {
        let a = VolumeCopyUp.anonymousVolumeName(container: "web", path: "/cache")
        XCTAssertEqual(a, VolumeCopyUp.anonymousVolumeName(container: "web", path: "/cache"))
        XCTAssertNotEqual(a, VolumeCopyUp.anonymousVolumeName(container: "web", path: "/data"))
        XCTAssertTrue(a.hasPrefix("web-anon-"))
    }
}
