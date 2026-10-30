import XCTest
@testable import AppCore

final class PortCheckTests: XCTestCase {
    func testReplacesOnlyTheHostPort() {
        XCTAssertEqual(PortCheck.replacingHostPort("8080:80", 8080, with: 8081), "8081:80")
        XCTAssertEqual(PortCheck.replacingHostPort("127.0.0.1:8080:80/tcp", 8080, with: 8081), "127.0.0.1:8081:80/tcp")
        XCTAssertEqual(PortCheck.replacingHostPort("8080:8080", 8080, with: 8081), "8081:8080")
        XCTAssertEqual(PortCheck.replacingHostPort("3000:80", 8080, with: 8081), "3000:80")
    }
}
