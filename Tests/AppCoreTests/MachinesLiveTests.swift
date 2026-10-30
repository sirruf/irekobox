import XCTest
import ContainerKit
@testable import AppCore

/// Drives the ibk-test machine: IREKOBOX_LIVE_MACHINES=1 swift test --filter MachinesLive
@MainActor
final class MachinesLiveTests: XCTestCase {
    func testMachineLifecycle() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IREKOBOX_LIVE_MACHINES"] == "1", "live only")
        let model = MachinesModel(cli: ContainerCLI())
        await model.refresh()
        var machine = try XCTUnwrap(model.machines.first { $0.id == "ibk-test" }, "\(model.error ?? "")")
        XCTAssertNotNil(machine.userSetup?.username)
        XCTAssertNotNil(machine.image)

        await model.stop("ibk-test")
        machine = try XCTUnwrap(model.machines.first { $0.id == "ibk-test" })
        XCTAssertFalse(machine.isRunning, model.error ?? "")

        await model.apply("ibk-test", [.cpus(2), .memory("2G")], restart: false)
        await model.start("ibk-test")
        machine = try XCTUnwrap(model.machines.first { $0.id == "ibk-test" })
        XCTAssertTrue(machine.isRunning, model.error ?? "")
        XCTAssertEqual(machine.cpus, 2)
        XCTAssertEqual(machine.memory, 2 << 30)

        let log = await model.logs("ibk-test", boot: true)
        XCTAssertFalse(log.isEmpty)
        print("boot log tail:", log.split(separator: "\n").suffix(2))
    }
}

/// Creates ibk-ub-NNNN from ubuntu:24.04 (systemd image built first), checks
/// it runs, deletes it: IREKOBOX_LIVE_MACHINE_CREATE=1 swift test --filter MachineCreateLive
@MainActor
final class MachineCreateLiveTests: XCTestCase {
    func testUbuntuMachineBoots() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IREKOBOX_LIVE_MACHINE_CREATE"] == "1", "live only")
        let model = MachinesModel(cli: ContainerCLI(), stream: CLIStream())
        // A fresh name: container may keep a deleted machine's hostname.
        let name = "ibk-ub-\(UInt16.random(in: 1000...9999))"
        let ok = await model.create(image: "ubuntu:24.04", name: name)
        XCTAssertTrue(ok, model.error ?? "")
        let machine = try XCTUnwrap(model.machines.first { $0.id == name })
        XCTAssertTrue(machine.isRunning)
        await model.stop(name)
        await model.delete(name)
        XCTAssertNil(model.machines.first { $0.id == name })
    }

    /// An image with no init: a clear message, no machine left behind.
    func testImageWithoutInitIsExplained() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IREKOBOX_LIVE_MACHINE_CREATE"] == "1", "live only")
        let model = MachinesModel(cli: ContainerCLI(), stream: CLIStream())
        let ok = await model.create(image: "pgvector/pgvector:pg16", name: "ibk-noinit")
        XCTAssertFalse(ok)
        XCTAssertTrue(model.error?.contains("no init system") == true, model.error ?? "")
        XCTAssertNil(model.machines.first { $0.id == "ibk-noinit" })
    }

    /// Rename keeps the disk: a file written before is there after.
    func testRenameKeepsTheDisk() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IREKOBOX_LIVE_MACHINE_CREATE"] == "1", "live only")
        let cli = ContainerCLI()
        let model = MachinesModel(cli: cli, stream: CLIStream())
        let suffix = UInt16.random(in: 1000...9999)
        let old = "ibk-ren-\(suffix)", new = "ibk-renamed-\(suffix)"
        let created = await model.create(image: "ubuntu:24.04", name: old)
        XCTAssertTrue(created, model.error ?? "")
        let containerId = try XCTUnwrap(model.machines.first { $0.id == old }?.containerId)
        try await cli.run(["exec", containerId, "sh", "-c", "echo kept > /opt/marker"])
        let renamed = await model.rename(old, to: new)
        XCTAssertTrue(renamed, model.error ?? "")
        XCTAssertNil(model.machines.first { $0.id == old })
        let machine = try XCTUnwrap(model.machines.first { $0.id == new })
        XCTAssertTrue(machine.isRunning)
        let marker = try await cli.data(["exec", try XCTUnwrap(machine.containerId), "cat", "/opt/marker"])
        XCTAssertEqual(String(decoding: marker, as: UTF8.self), "kept\n")
        await model.delete(new)
        XCTAssertNil(model.machines.first { $0.id == new })
    }
}
