import XCTest
import Darwin
import ContainerKit
@testable import AppCore

final class PortCheckTests: XCTestCase {
    func testBindProbeUsesThePublishedAddressAndReleasesItsSocket() async throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, size) }
        }
        if bound != 0 && errno == EPERM { throw XCTSkip("The test sandbox denies socket binding") }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        var length = size
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        XCTAssertEqual(named, 0)
        let port = Int(UInt16(bigEndian: address.sin_port))
        XCTAssertEqual(PortCheck.bindError(port: port, address: "127.0.0.1"), EADDRINUSE)
        XCTAssertNil(PortCheck.bindError(port: port), "with SO_REUSEADDR the wildcard binds beside loopback")
        XCTAssertEqual(PortCheck.bindError(port: port, reuse: false), EADDRINUSE)
        let inUse = await PortCheck.inUse(port: port, address: nil)
        XCTAssertTrue(inUse, "localhost clients would reach this listener")
        XCTAssertNil(PortCheck.bindError(port: port, address: "::1"), "IPv6 loopback is separate")
        XCTAssertNil(PortCheck.bindError(port: port, address: "::1"), "the probe closes its socket")
    }

    func testASpecificAddressNextToAWildcardListenerIsInUse() async throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }
        var reuse: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, size) }
        }
        if bound != 0 && errno == EPERM { throw XCTSkip("The test sandbox denies socket binding") }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        var length = size
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))
        XCTAssertNil(PortCheck.bindError(port: port, address: "127.0.0.1"), "SO_REUSEADDR lets loopback bind beside it")
        let loopback = await PortCheck.inUse(port: port, address: "127.0.0.1")
        XCTAssertTrue(loopback, "but localhost clients would reach the other program")
        let wildcard = await PortCheck.inUse(port: port, address: nil)
        XCTAssertTrue(wildcard)
    }

    func testOwnerLookupMatchesThePublishedAddress() {
        let output = "p11\ncother\nn127.0.0.2:8080\np22\ncloopback\nn127.0.0.1:8080\np33\ncwildcard\nn*:8080\n"
        XCTAssertEqual(PortCheck.owner(in: output, port: 8080, address: "127.0.0.1")?.pid, 22)
        XCTAssertEqual(PortCheck.owner(in: output, port: 8080, address: "127.0.0.3")?.pid, 33)
        XCTAssertEqual(PortCheck.owner(in: output, port: 8080)?.pid, 11)
        XCTAssertNil(PortCheck.owner(in: "p11\ncother\nn127.0.0.2:8080\n", port: 8080, address: "127.0.0.1"))
    }

    func testPublishedRangesKeepTheirAddressAndSkipUDP() {
        let bindings = PortCheck.bindings([
            .init(containerPort: 80, hostPort: 8080, hostAddress: "::1", count: 3),
            .init(containerPort: 53, hostPort: 8053, proto: "udp"),
        ])
        XCTAssertEqual(bindings.map(\.hostPort), [8080, 8081, 8082])
        XCTAssertTrue(bindings.allSatisfy { $0.hostAddress == "::1" && $0.rangeStart == 8080 && $0.rangeCount == 3 })
        XCTAssertEqual(PortCheck.replacingHostPort("[::1]:8080-8082:80-82", 8081, with: 9081), "[::1]:9080-9082:80-82")
        XCTAssertEqual(PortCheck.replacingHostPort("8080-8082:80-82", 8081, with: 65535), "8080-8082:80-82")
    }

    func testInvalidPortsAndAddressesDoNotTrap() {
        XCTAssertEqual(PortCheck.bindError(port: -1), EINVAL)
        XCTAssertEqual(PortCheck.bindError(port: 65_536), EINVAL)
        XCTAssertEqual(PortCheck.bindError(port: 8080, address: "invalid"), EINVAL)
    }

    func testReplacesOnlyTheHostPort() {
        XCTAssertEqual(PortCheck.replacingHostPort("8080:80", 8080, with: 8081), "8081:80")
        XCTAssertEqual(PortCheck.replacingHostPort("127.0.0.1:8080:80/tcp", 8080, with: 8081), "127.0.0.1:8081:80/tcp")
        XCTAssertEqual(PortCheck.replacingHostPort("8080:8080", 8080, with: 8081), "8081:8080")
        XCTAssertEqual(PortCheck.replacingHostPort("3000:80", 8080, with: 8081), "3000:80")
    }
}
