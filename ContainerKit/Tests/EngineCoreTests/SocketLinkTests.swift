import XCTest
@testable import EngineCore

final class SocketLinkTests: XCTestCase {
    let ours = "/Users/me/.irekobox/docker.sock"
    let desktop = "/Users/me/.docker/run/docker.sock"

    func testTakingOverRemembersDockerDesktopAndGivesItBack() {
        let (take, taken) = SocketLink.plan(wanted: true, target: ours, current: desktop, currentIsLive: true,
                                            state: SocketLink.State())
        XCTAssertEqual(take, .link(to: ours))
        XCTAssertEqual(taken, SocketLink.State(previous: desktop, linked: ours))

        let (steady, same) = SocketLink.plan(wanted: true, target: ours, current: ours, currentIsLive: true, state: taken)
        XCTAssertEqual(steady, .none)
        XCTAssertEqual(same, taken)

        let (giveBack, cleared) = SocketLink.plan(wanted: false, target: ours, current: ours, currentIsLive: true, state: taken)
        XCTAssertEqual(giveBack, .link(to: desktop))
        XCTAssertEqual(cleared, SocketLink.State())
    }

    func testNoTugOfWarWithALiveOtherSocket() {
        let state = SocketLink.State(previous: desktop, linked: ours)
        let (yield, _) = SocketLink.plan(wanted: true, target: ours, current: desktop, currentIsLive: true, state: state)
        XCTAssertEqual(yield, .none, "Docker Desktop took it back while running: leave it")
        let (repair, _) = SocketLink.plan(wanted: true, target: ours, current: desktop, currentIsLive: false, state: state)
        XCTAssertEqual(repair, .link(to: ours), "dangling: ours again")
        let (missing, _) = SocketLink.plan(wanted: true, target: ours, current: nil, currentIsLive: false, state: state)
        XCTAssertEqual(missing, .link(to: ours), "/var/run is emptied at boot")
    }

    func testTurningOffLeavesSomeoneElsesLinkAndRemovesOursWithoutPrevious() {
        let taken = SocketLink.State(previous: nil, linked: ours)
        let (remove, _) = SocketLink.plan(wanted: false, target: ours, current: ours, currentIsLive: true, state: taken)
        XCTAssertEqual(remove, .remove)
        let (leave, cleared) = SocketLink.plan(wanted: false, target: ours, current: desktop, currentIsLive: true, state: taken)
        XCTAssertEqual(leave, .none)
        XCTAssertEqual(cleared, SocketLink.State())
        let (idle, _) = SocketLink.plan(wanted: false, target: ours, current: desktop, currentIsLive: true, state: SocketLink.State())
        XCTAssertEqual(idle, .none)
    }

    func testMakeLinkReplacesAtomically() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ib-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = folder.appending(path: "docker.sock").path
        try SocketLink.makeLink(link, to: "/a")
        try SocketLink.makeLink(link, to: "/b")
        XCTAssertEqual(SocketLink.readLink(link), "/b")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["docker.sock"])
    }
}
