import XCTest
import ContainerKit
@testable import AppCore

@MainActor
final class EditContainerModelTests: XCTestCase {
    private func container() throws -> Container {
        let json = #"""
        [{"id":"web","status":{"networks":[],"state":"running"},"configuration":{"id":"web","image":{"reference":"nginx","descriptor":{"digest":"sha256:x","mediaType":"m","size":1}},"resources":{"cpus":2,"memoryInBytes":1073741824,"cpuOverhead":1},"platform":{"architecture":"arm64","os":"linux"},"networks":[{"network":"default","options":{"hostname":"web","mtu":1280}}],"initProcess":{"executable":"nginx","arguments":[],"workingDirectory":"/","environment":["A=1"]},"labels":{},"creationDate":"2026-06-10T00:00:00Z","readOnly":false,"runtimeHandler":"r","rosetta":false,"publishedPorts":[{"containerPort":80,"hostPort":8080,"hostAddress":"0.0.0.0","proto":"tcp"}],"mounts":[]}}]
        """#
        return try XCTUnwrap(JSONDecoder().decode([Container].self, from: json.data(using: .utf8)!).first)
    }

    func testResourcesAreEditable() throws {
        let model = EditContainerModel(container: try container())
        XCTAssertEqual(model.cpus, 2)
        XCTAssertEqual(model.memoryMiB, 1024)
        model.memoryMiB = 2048
        XCTAssertEqual(model.changeCount, 1)
        let arguments = ContainerRecreate.runArguments(for: try container(), edits: model.buildEdits())
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--memory")! + 1], "2048M")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--cpus")! + 1], "2")
    }

    func testCountsChanges() throws {
        let model = EditContainerModel(container: try container())
        XCTAssertEqual(model.changeCount, 0)
        model.env[0].value = "2"
        XCTAssertEqual(model.changeCount, 1, "a changed value is one change")
        model.ports.append(.init(host: "8443", container: "443"))
        model.networks.append(.init())   // a blank row is no change
        XCTAssertEqual(model.changeCount, 2)
        model.env[0].value = "1"
        XCTAssertEqual(model.changeCount, 1)
    }

    func testPrefillFromContainer() throws {
        let model = EditContainerModel(container: try container())
        XCTAssertEqual(model.env.map(\.key), ["A"])
        XCTAssertEqual(model.env.first?.value, "1")
        XCTAssertEqual(model.ports.first?.host, "8080")
        XCTAssertEqual(model.ports.first?.container, "80")
        XCTAssertEqual(model.networks.map(\.name), ["default"])
    }

    func testValidationFlags() throws {
        let model = EditContainerModel(container: try container())
        XCTAssertTrue(model.isValid)

        model.ports.append(.init(host: "70000", container: "80"))   // out of range
        XCTAssertFalse(model.isValid)
        XCTAssertNotNil(model.portError(model.ports.last!))

        model.ports.removeLast()
        model.env.append(.init(key: "bad name", value: "x"))        // invalid name
        XCTAssertFalse(model.isValid)

        model.env.removeLast()
        model.volumes.append(.init(source: "data", destination: "relative"))  // not absolute
        XCTAssertFalse(model.isValid)
    }

    func testBlankRowsIgnored() throws {
        let model = EditContainerModel(container: try container())
        model.env.append(.init())          // blank → ignored
        model.ports.append(.init())
        XCTAssertTrue(model.isValid)
        let edits = model.buildEdits()
        XCTAssertEqual(edits.environment, ["A=1"])           // blank env dropped
        XCTAssertEqual(edits.ports, ["8080:80"])             // blank port dropped, tcp implicit
    }

    func testBuildEditsFormats() throws {
        let model = EditContainerModel(container: try container())
        model.ports.append(.init(host: "53", container: "53", proto: "udp"))
        model.volumes.append(.init(source: "cache", destination: "/data", readOnly: true))
        let edits = model.buildEdits()
        XCTAssertTrue(edits.ports.contains("53:53/udp"))
        XCTAssertTrue(edits.volumes.contains("cache:/data:ro"))
    }
}
