import XCTest
@testable import ContainerKit

final class LabelValueTests: XCTestCase {
    func testValuesWithEqualsRoundTripAndOthersStayAsIs() {
        let health = #"{"Test":["CMD-SHELL","mysqladmin ping --password=\"$(cat /run/secrets/db)\""]}"#
        let encoded = LabelValue.encode(health)
        XCTAssertTrue(encoded.hasPrefix("ib64:"))
        XCTAssertFalse(encoded.contains("="), "container refuses = in a value")
        XCTAssertEqual(LabelValue.decode(encoded), health)
        XCTAssertEqual(LabelValue.encode("plain value"), "plain value")
        XCTAssertEqual(LabelValue.decode("plain value"), "plain value")
    }

    func testContainerLabelsReadBackDecoded() throws {
        let value = "a=b"
        let json = """
        {"id":"web","status":{"networks":[],"state":"running"},"configuration":{"id":"web",
         "image":{"reference":"nginx","descriptor":{"digest":"sha256:x","mediaType":"m","size":1}},
         "resources":{"cpus":1,"memoryInBytes":1,"cpuOverhead":1},"platform":{"architecture":"arm64","os":"linux"},
         "networks":[],"initProcess":{"executable":"nginx","arguments":[],"workingDirectory":"/","environment":[]},
         "labels":{"k":"\(LabelValue.encode(value))","plain":"x"},"creationDate":"2026-10-30T00:00:00Z",
         "readOnly":false,"runtimeHandler":"r","rosetta":false}}
        """
        let container = try JSONDecoder().decode(Container.self, from: Data(json.utf8))
        XCTAssertEqual(container.configuration.labels, ["k": value, "plain": "x"])
    }

    func testVolumeAndNetworkLabelsReadBackDecoded() throws {
        let encoded = LabelValue.encode("--password=secret")
        let volume = try JSONDecoder().decode(Volume.self, from: Data("""
            {"id":"v","configuration":{"name":"v","driver":"local","labels":{"k":"\(encoded)","plain":"x"}}}
            """.utf8))
        XCTAssertEqual(volume.configuration.labels?["k"], "--password=secret")
        XCTAssertEqual(volume.configuration.labels?["plain"], "x")
        let network = try JSONDecoder().decode(Network.self, from: Data("""
            {"id":"n","configuration":{"name":"n","labels":{"k":"\(encoded)"}}}
            """.utf8))
        XCTAssertEqual(network.configuration.labels?["k"], "--password=secret")
        // Encoding back writes what `container` stored, not the decoded text.
        let roundTrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(volume)) as? [String: Any]
        let labels = (roundTrip?["configuration"] as? [String: Any])?["labels"] as? [String: String]
        XCTAssertEqual(labels?["k"], encoded)
    }
}
