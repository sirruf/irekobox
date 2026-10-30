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
