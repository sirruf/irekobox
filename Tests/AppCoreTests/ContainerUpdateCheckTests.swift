import XCTest
@testable import AppCore

@MainActor
final class ContainerUpdateCheckTests: XCTestCase {

    private func defaults() -> UserDefaults {
        let suite = "ib-tests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private let payload = Data(#"{"tag_name":"1.7.0","html_url":"https://github.com/apple/container/releases/tag/1.7.0","name":"1.7.0"}"#.utf8)

    func testVersionComparison() {
        XCTAssertEqual(ContainerUpdateCheck.compare("1.10.0", "1.9.2"), .orderedDescending)
        XCTAssertEqual(ContainerUpdateCheck.compare("v1.6.1", "1.6.1"), .orderedSame)
        XCTAssertEqual(ContainerUpdateCheck.compare("1.6", "1.6.0"), .orderedSame)
        XCTAssertEqual(ContainerUpdateCheck.compare("1.6.1", "1.7.0-rc1"), .orderedAscending)
    }

    func testReportsANewerRelease() async {
        let check = ContainerUpdateCheck(defaults: defaults(), fetch: { [payload] _ in payload })
        await check.checkIfDue()
        XCTAssertEqual(check.update(over: "1.6.1")?.version, "1.7.0")
        XCTAssertNil(check.update(over: "1.7.0"), "up to date")
        XCTAssertNil(check.update(over: nil), "engine version unknown")
    }

    func testChecksAtMostDailyAndRemembers() async {
        let store = defaults()
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let check = ContainerUpdateCheck(defaults: store, fetch: { [payload] _ in counter.calls += 1; return payload })
        await check.checkIfDue()
        await check.checkIfDue()
        XCTAssertEqual(counter.calls, 1)

        // A new instance (next launch) knows the release without fetching.
        let relaunched = ContainerUpdateCheck(defaults: store, fetch: { _ in XCTFail("no fetch"); return Data() })
        XCTAssertEqual(relaunched.update(over: "1.6.1")?.version, "1.7.0")
    }

    func testDisabledNeverFetchesOrReports() async {
        let store = defaults()
        let check = ContainerUpdateCheck(defaults: store, fetch: { _ in XCTFail("no fetch"); return Data() })
        check.isEnabled = false
        await check.checkIfDue(force: true)
        XCTAssertNil(check.update(over: "0.1"))
    }

    func testOfflineKeepsWhatWasKnown() async {
        let check = ContainerUpdateCheck(defaults: defaults(), fetch: { _ in throw URLError(.notConnectedToInternet) })
        await check.checkIfDue()
        XCTAssertNil(check.latest)
    }
}
