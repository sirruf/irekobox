import XCTest
@testable import ContainerKit

final class MachineNameTests: XCTestCase {
    /// `container` derives `ubuntu-24.04` from the image and then refuses it.
    func testSuggestedNamesAreValid() {
        XCTAssertEqual(MachineRepository.suggestedName(for: "ubuntu:24.04"), "ubuntu-24-04")
        XCTAssertEqual(MachineRepository.suggestedName(for: "alpine:latest"), "alpine")
        XCTAssertEqual(MachineRepository.suggestedName(for: "docker.io/library/Fedora:41"), "fedora-41")
        XCTAssertEqual(MachineRepository.suggestedName(for: "ubuntu:24.04", taken: ["ubuntu-24-04"]), "ubuntu-24-04-2")
        for image in ["ubuntu:24.04", "debian:12", "archlinux:latest", "ghcr.io/x/y_z:1.2.3", "___"] {
            XCTAssertTrue(MachineRepository.isValidName(MachineRepository.suggestedName(for: image)), image)
        }
        XCTAssertFalse(MachineRepository.isValidName("ubuntu-24.04"))
        XCTAssertFalse(MachineRepository.isValidName("-dev"))
        XCTAssertTrue(MachineRepository.isValidName("dev-1"))
    }
}

/// Replays `machine list` and `machine inspect` and counts the inspects.
private final class MachineCLI: ContainerCommanding, @unchecked Sendable {
    var listed: String
    var inspected: String
    private(set) var inspects: [String] = []

    init(listed: String, inspected: String) {
        self.listed = listed
        self.inspected = inspected
    }

    func data(_ arguments: [String]) async throws -> Data {
        if arguments.starts(with: ["machine", "inspect"]) {
            inspects.append(arguments[2])
            return Data(inspected.utf8)
        }
        return Data(listed.utf8)
    }

    func decode<T: Decodable & Sendable>(_ type: T.Type, _ arguments: [String],
                                         alsoAccepting exitCodes: Set<Int32>) async throws -> T {
        try JSONDecoder().decode(T.self, from: await data(arguments))
    }

    func run(_ arguments: [String], workingDirectory: URL?) async throws {}
    func run(_ arguments: [String], input: Data, workingDirectory: URL?) async throws {}
}

final class MachineRepositoryTests: XCTestCase {
    private let row = #"{"id":"dev","status":"running","cpus":2,"memory":2147483648,"diskSize":100,"ipAddress":"192.168.66.2","createdDate":"2026-10-26T11:19:03Z","default":true}"#
    private let detail = #"{"id":"dev","status":"running","cpus":2,"memory":2147483648,"diskSize":100,"ipAddress":"192.168.66.2","createdDate":"2026-10-26T11:19:03Z","startedDate":"2026-10-26T11:19:04Z","homeMount":"rw","containerId":"dev-61bb20","image":{"reference":"docker.io/library/alpine:latest"}}"#

    /// A machine whose `list` row is as before keeps its details without an
    /// `inspect`; a change in the row (or a new machine) is inspected.
    func testUnchangedMachinesAreNotInspectedAgain() async throws {
        let cli = MachineCLI(listed: "[\(row)]", inspected: "[\(detail)]")
        let repository = MachineRepository(cli: cli)

        let first = try await repository.list()
        XCTAssertEqual(cli.inspects, ["dev"])
        XCTAssertEqual(first.first?.homeMount, "rw")
        XCTAssertEqual(first.first?.containerId, "dev-61bb20")

        let again = try await repository.list(known: first)
        XCTAssertEqual(cli.inspects, ["dev"], "nothing changed, so no inspect")
        XCTAssertEqual(again, first)

        cli.listed = "[\(row.replacingOccurrences(of: "\"running\"", with: "\"stopped\""))]"
        cli.inspected = "[\(detail.replacingOccurrences(of: "\"running\"", with: "\"stopped\""))]"
        let stopped = try await repository.list(known: first)
        XCTAssertEqual(cli.inspects, ["dev", "dev"])
        XCTAssertEqual(stopped.first?.status, "stopped")
        XCTAssertEqual(stopped.first?.homeMount, "rw")

        _ = try await repository.list(known: [])
        XCTAssertEqual(cli.inspects.count, 3, "without known machines every one is inspected")
    }
}

final class MachineImageTests: XCTestCase {
    func testWhichImagesArePrepared() {
        XCTAssertEqual(MachineImage.family(of: "ubuntu:24.04"), .apt)
        XCTAssertEqual(MachineImage.family(of: "docker.io/library/debian:12"), .apt)
        XCTAssertEqual(MachineImage.family(of: "fedora:41"), .dnf)
        XCTAssertEqual(MachineImage.family(of: "alpine:latest"), .ready)
        XCTAssertEqual(MachineImage.family(of: "ghcr.io/me/tool:1"), .unknown)
        XCTAssertEqual(MachineImage.preparedTag(for: "ubuntu:24.04"), "irekobox-machine-ubuntu:24.04")
        XCTAssertEqual(MachineImage.preparedTag(for: "debian"), "irekobox-machine-debian:latest")
        XCTAssertTrue(MachineImage.dockerfile(for: "ubuntu:24.04")!.contains("FROM ubuntu:24.04\nRUN apt-get update"))
        XCTAssertTrue(MachineImage.dockerfile(for: "fedora:41")!.contains("dnf install -y systemd"))
        XCTAssertNil(MachineImage.dockerfile(for: "alpine:latest"))
    }
}
