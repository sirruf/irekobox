import XCTest
@testable import DockerAPIKit

final class ResponseFormattingTests: XCTestCase {

    func testHTTPDateExactFormat() {
        XCTAssertEqual(DockerAPIServer.httpDate(Date(timeIntervalSince1970: 0)), "Thu, 01 Jan 1970 00:00:00 GMT")
        XCTAssertEqual(DockerAPIServer.httpDate(Date(timeIntervalSince1970: 1_800_000_000.125)), "Fri, 15 Jan 2027 08:00:00 GMT")
    }

    func testSystemTimeExactFormat() {
        XCTAssertEqual(DockerTime.string(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(DockerTime.string(Date(timeIntervalSince1970: 1_800_000_000.125)), "2027-01-15T08:00:00.125Z")
    }

    func testJSONResponsePreservesSlashesNewlineAndErrorFallback() {
        let response = HTTPResponse.json(["path": "/containers/name"])
        XCTAssertTrue(response.headers.contains { $0 == ("Content-Type", "application/json") })
        guard case .data(let data) = response.body else { return XCTFail("not data") }
        XCTAssertEqual(data, Data("{\"path\":\"/containers/name\"}\n".utf8))
        let invalid = HTTPResponse.json(Double.nan)
        guard case .data(let fallback) = invalid.body else { return XCTFail("not data") }
        XCTAssertEqual(fallback, Data("{}\n".utf8))
    }

    func testConcurrentJSONResponsesAndTimestamps() async {
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    let response = HTTPResponse.json(["path": "/\(index)"])
                    guard case .data(let data) = response.body else { return XCTFail("not data") }
                    XCTAssertEqual(data, Data("{\"path\":\"/\(index)\"}\n".utf8))
                    XCTAssertEqual(LogsStatsAPI.timestamp(Date(timeIntervalSince1970: 0.125)), "1970-01-01T00:00:00.125000000Z")
                    XCTAssertEqual(DockerAPIServer.httpDate(Date(timeIntervalSince1970: 0)), "Thu, 01 Jan 1970 00:00:00 GMT")
                }
            }
        }
    }
}
