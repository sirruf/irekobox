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

    func testNetworkLabelKeysDockerAllowsRoundTrip() throws {
        let given = ["MyKey": "1", "my_key": "2", "com.docker.compose.project": "shop", "Tier.Front/End": "3", "_": "4"]
        let stored = LabelKey.encode(given)
        XCTAssertTrue(stored.keys.allSatisfy(LabelKey.isValid), "\(stored.keys.sorted())")
        XCTAssertEqual(stored["com.docker.compose.project"], "shop", "valid keys stay as they are")
        XCTAssertEqual(stored["my-key"], "2")
        XCTAssertEqual(stored["tier.front/end"], "3")
        XCTAssertEqual(LabelKey.decode(stored), given)
        XCTAssertEqual(LabelKey.encode(["a.b/c": "x"]), ["a.b/c": "x"], "nothing added when every key is valid")

        let raw = stored.mapValues(LabelValue.encode)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["id": "n", "configuration": ["name": "n", "labels": raw]]),
                          as: UTF8.self)
        let network = try JSONDecoder().decode(Network.self, from: Data(json.utf8))
        XCTAssertEqual(network.configuration.labels, given)
    }

    func testLabelKeyRuleMatchesContainers() {
        for key in ["a", "com.example", "a-b.c/d.e", "x/y/z"] { XCTAssertTrue(LabelKey.isValid(key), key) }
        for key in ["A", "a_b", "-a", "a-", "a..b", "a/", "", String(repeating: "a", count: 129)] {
            XCTAssertFalse(LabelKey.isValid(key), key)
        }
    }
}
