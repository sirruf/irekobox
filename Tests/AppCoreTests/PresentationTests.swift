import XCTest
import ContainerKit
@testable import AppCore

final class PresentationTests: XCTestCase {

    func testDurationIsCompact() {
        XCTAssertEqual(Format.duration(42), "42s")
        XCTAssertEqual(Format.duration(4 * 60 + 5), "4m")
        XCTAssertEqual(Format.duration(2 * 3600 + 14 * 60), "2h 14m")
        XCTAssertEqual(Format.duration(3 * 3600), "3h")
        XCTAssertEqual(Format.duration(3 * 86_400 + 2 * 3600 + 59), "3d 2h")
        XCTAssertEqual(Format.duration(-5), "0s")
    }

    func testMemoryUsesBinaryUnits() {
        XCTAssertEqual(Format.memory(1_073_741_824), "1 GB")
        XCTAssertEqual(Format.memory(536_870_912), "512 MB")
    }

    func testTCPPortOpensLocalhost() {
        let link = PortLink(Container.PublishedPort(containerPort: 80, hostPort: 3000, hostAddress: "0.0.0.0"))
        XCTAssertEqual(link.label, ":3000")
        XCTAssertEqual(link.url?.absoluteString, "http://localhost:3000")
    }

    func testUDPPortHasNothingToOpen() {
        let link = PortLink(Container.PublishedPort(containerPort: 53, hostPort: 5353, proto: "UDP"))
        XCTAssertEqual(link.label, ":5353/udp")
        XCTAssertNil(link.url)
    }

    func testPortBoundToSpecificInterface() {
        let v4 = PortLink(Container.PublishedPort(containerPort: 80, hostPort: 8080, hostAddress: "127.0.0.1"))
        XCTAssertEqual(v4.url?.absoluteString, "http://127.0.0.1:8080")
        let v6 = PortLink(Container.PublishedPort(containerPort: 80, hostPort: 8080, hostAddress: "::1"))
        XCTAssertEqual(v6.url?.absoluteString, "http://[::1]:8080")
    }

    func testStateTones() {
        XCTAssertEqual(Tone(.running), .positive)
        XCTAssertEqual(Tone(.stopping), .warning)
        XCTAssertEqual(Tone(.stopped), .neutral)
        XCTAssertEqual(Tone(.unknown("paused")), .inactive)
    }

    func testPresentationOfARunningContainerWithPorts() throws {
        let json = """
        {"id":"web","status":{"state":"running","networks":[],"startedDate":"2026-10-25T10:00:00Z"},\
        "configuration":{"id":"web","image":{"reference":"nginx","descriptor":{"digest":"d","mediaType":"m","size":1}},\
        "resources":{"cpus":1,"memoryInBytes":1},"platform":{"architecture":"arm64","os":"linux"},"networks":[],\
        "initProcess":{"executable":"nginx","arguments":[],"workingDirectory":"/","environment":[]},"labels":{},\
        "creationDate":"2026-10-25T09:00:00Z","readOnly":false,"runtimeHandler":"r","rosetta":false,\
        "publishedPorts":[{"containerPort":80,"hostPort":8080,"hostAddress":"0.0.0.0","proto":"tcp","count":1}]}}
        """
        let container = try JSONDecoder().decode(Container.self, from: Data(json.utf8))
        let presentation = ContainerPresentation(container)
        XCTAssertEqual(presentation.tone, .positive)
        XCTAssertEqual(presentation.label, "Running")
        XCTAssertEqual(presentation.ports.map(\.label), [":8080"])

        let now = try XCTUnwrap(Format.date(fromISO: "2026-10-25T12:14:00Z"))
        XCTAssertEqual(ContainerPresentation.uptime(container, now: now), "2h 14m")
    }
}
