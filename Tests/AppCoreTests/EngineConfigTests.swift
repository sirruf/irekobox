import XCTest
@testable import AppCore

final class EngineConfigTests: XCTestCase {

    // `container system property list` output (1.6.1), trimmed.
    private let listing = """
    [build]
    cpus = 2
    memory = "2048mb"
    rosetta = true

    [container]
    cpus = 4
    memory = "1gb"

    [dns]

    [kernel]
    url = "https://github.com/kata-containers/kata-containers/releases/download/3.32.0/kata-static-3.32.0-arm64.tar.zst"
    """

    func testParsesTheListing() {
        let tables = EngineConfig.parse(listing)
        XCTAssertEqual(tables["container"]?["cpus"], "4")
        XCTAssertEqual(tables["container"]?["memory"], "1gb")
        XCTAssertEqual(tables["build"]?["rosetta"], "true")
        XCTAssertEqual(tables["dns"], [:])
        XCTAssertTrue(tables["kernel"]?["url"]?.hasPrefix("https://") == true)
    }

    func testChangesAKeyAndKeepsTheRest() {
        let file = """
        # my settings
        [container]
        cpus = 4
        memory = "1gb"

        [build]
        rosetta = false
        """
        let updated = EngineConfig.setting("cpus", in: "container", to: "6", of: file)
        XCTAssertEqual(updated, """
        # my settings
        [container]
        cpus = 6
        memory = "1gb"

        [build]
        rosetta = false

        """)
    }

    func testAddsKeysAndTables() {
        let withKey = EngineConfig.setting("memory", in: "build", to: "\"4g\"", of: "[build]\ncpus = 2\n\n[dns]\n")
        XCTAssertEqual(withKey, "[build]\ncpus = 2\nmemory = \"4g\"\n\n[dns]\n")

        let fresh = EngineConfig.setting("cpus", in: "container", to: "2", of: "")
        XCTAssertEqual(fresh, "[container]\ncpus = 2\n")

        let appended = EngineConfig.setting("cpus", in: "container", to: "2", of: "[build]\ncpus = 2\n")
        XCTAssertEqual(appended, "[build]\ncpus = 2\n\n[container]\ncpus = 2\n")
    }

    func testRemovesAKey() {
        let updated = EngineConfig.setting("cpus", in: "container", to: nil, of: "[container]\ncpus = 6\nmemory = \"1gb\"\n")
        XCTAssertEqual(updated, "[container]\nmemory = \"1gb\"\n")
        XCTAssertEqual(EngineConfig.setting("cpus", in: "nope", to: nil, of: "[a]\n"), "[a]\n")
    }

    func testWritesTheUserFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ib-config-\(UUID().uuidString)")
        let file = folder.appending(path: "container/config.toml")
        try EngineConfig.write("cpus", in: "container", value: "3", file: file)
        try EngineConfig.write("memory", in: "container", value: "\"2g\"", file: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "[container]\ncpus = 3\nmemory = \"2g\"\n")
        try? FileManager.default.removeItem(at: folder)
    }

    func testMemoryUnits() {
        XCTAssertEqual(EngineConfig.bytes("1gb"), 1 << 30)
        XCTAssertEqual(EngineConfig.bytes("2048mb"), 2048 << 20)
        XCTAssertEqual(EngineConfig.bytes("512m"), 512 << 20)
        XCTAssertNil(EngineConfig.bytes("lots"))
    }

    func testSavedValuesOverlayTheEffectiveOnes() {
        let effective: EngineConfig.Tables = ["container": ["cpus": "4", "memory": "1gb"], "dns": [:]]
        let saved: EngineConfig.Tables = ["container": ["cpus": "6"], "build": ["rosetta": "false"]]
        let merged = EngineConfig.overlay(saved, on: effective)
        XCTAssertEqual(merged["container"], ["cpus": "6", "memory": "1gb"])
        XCTAssertEqual(merged["build"], ["rosetta": "false"])
        XCTAssertEqual(merged["dns"], [:])
        XCTAssertEqual(EngineConfig.overlay([:], on: effective), effective)
    }

    func testCompactsEngineLogLines() {
        let line: Substring = "2026-10-25 23:42:19.155027-0700 0x9406cf8  Error       0x0                  50975  0    container-core-images: [ImagesHelper] connection error [error=Connection invalid]"
        XCTAssertEqual(TroubleshootPane.compact(line),
                       "23:42:19  Error  container-core-images: [ImagesHelper] connection error [error=Connection invalid]")
        XCTAssertEqual(TroubleshootPane.compact("Couldn't read the engine logs"), "Couldn't read the engine logs")
    }
}
