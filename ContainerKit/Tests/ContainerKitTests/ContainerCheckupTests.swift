import XCTest
@testable import ContainerKit

final class ContainerCheckupTests: XCTestCase {
    func testReadsListenersFromProcNet() {
        // Captured from python -m http.server --bind 127.0.0.1 and nginx.
        let text = """
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 0100007F:1F40 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 2082 1
           1: 00000000:0050 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 2275 1
           2: 0242A8C0:0050 0142A8C0:D3A2 01 00000000:00000000 00:00000000 00000000     0        0 2276 1
          sl  local_address                         remote_address                        st
           0: 00000000000000000000000000000000:1F90 00000000000000000000000000000000:0000 0A 0
           1: 00000000000000000000000001000000:0BB8 00000000000000000000000000000000:0000 0A 0
        """
        let listeners = ContainerCheckup.listeners(procNet: text)
        XCTAssertEqual(listeners, [
            .init(address: "::", port: 8080), .init(address: "0.0.0.0", port: 80),
            .init(address: "::1", port: 3000), .init(address: "127.0.0.1", port: 8000),
        ].sorted { ($0.port, $0.address) < ($1.port, $1.address) })
        XCTAssertFalse(listeners.contains { $0.address == "192.168.66.2" }, "established sockets aren't listeners")
    }

    func testPortVerdicts() {
        func verdict(_ reach: ContainerCheckup.Reach, owner: String? = "container-runtime-linux", own: Bool = true,
                     inside: [ContainerCheckup.Listener]?, direct: ContainerCheckup.Reach? = nil) -> ContainerCheckup.Finding {
            ContainerCheckup.port(host: 8080, container: 80, reach: reach, hostOwner: owner, ownForwarder: own,
                                  inside: inside, direct: direct)
        }
        XCTAssertEqual(verdict(.open, inside: nil).level, .ok)
        XCTAssertEqual(verdict(.dropped, inside: [.init(address: "127.0.0.1", port: 80)]).level, .problem,
                       "the inside view explains a dropped forward")
        XCTAssertTrue(verdict(.dropped, inside: nil).detail.contains("closes them at once"))
        XCTAssertTrue(verdict(.refused, owner: "Docker Desktop", own: false, inside: nil).detail.contains("Docker Desktop"))
        let loopback = verdict(.refused, inside: [.init(address: "127.0.0.1", port: 80)])
        XCTAssertEqual(loopback.level, .problem)
        XCTAssertTrue(loopback.fix?.contains("0.0.0.0") == true)
        let wrongPort = verdict(.refused, inside: [.init(address: "0.0.0.0", port: 3000)])
        XCTAssertTrue(wrongPort.detail.contains("listens on 3000"))
        let nothing = verdict(.refused, inside: [])
        XCTAssertTrue(nothing.detail.contains("nothing listens at all"))
        XCTAssertTrue(verdict(.refused, inside: [.init(address: "0.0.0.0", port: 80)], direct: .open).fix == "Restart the container.")
        XCTAssertTrue(verdict(.refused, inside: [.init(address: "::", port: 80)], direct: .unreachable).fix?.contains("Local Network") == true)
    }

    func testMemoryKeptByTheVM() {
        XCTAssertEqual(ContainerCheckup.memory(footprint: 360 << 20, used: 16 << 20, limit: 1 << 30).level, .ok, "idle VM overhead")
        XCTAssertEqual(ContainerCheckup.memory(footprint: 3 << 30, used: 200 << 20, limit: 4 << 30).level, .warning)
        XCTAssertEqual(ContainerCheckup.memory(footprint: 900 << 20, used: 100 << 20, limit: 1 << 30).level, .warning,
                       "most of a small limit held while little is used")
    }

    func testBindMountHints() {
        let node = ContainerCheckup.mount(.init(source: "/Users/me/app", destination: "/app", heavyFolders: ["node_modules"],
                                                fileCount: 1000, countCapped: false))
        XCTAssertEqual(node.level, .warning)
        XCTAssertEqual(node.fix, "Put node_modules in a named volume: -v node_modules-cache:/app/node_modules")
        let big = ContainerCheckup.mount(.init(source: "/Users/me/data", destination: "/d", heavyFolders: [], fileCount: 20000, countCapped: true))
        XCTAssertEqual(big.level, .info)
        XCTAssertEqual(ContainerCheckup.mount(.init(source: "/x", destination: "/y", heavyFolders: [], fileCount: 3, countCapped: false)).level, .ok)
    }
}
