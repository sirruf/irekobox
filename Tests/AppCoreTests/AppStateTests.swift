import XCTest
@testable import AppCore

@MainActor
final class AppStateTests: XCTestCase {
    func testBinaryAvailableReflectsConfiguredPath() {
        let original = Settings.shared.binaryPath
        defer { Settings.shared.binaryPath = original }

        let app = AppState()
        Settings.shared.binaryPath = "/no/such/binary/xyz-\(UUID().uuidString)"
        XCTAssertFalse(app.binaryAvailable)

        Settings.shared.binaryPath = "/bin/sh"
        XCTAssertTrue(app.binaryAvailable)
    }

    func testRefreshSecondsIsClamped() {
        let original = Settings.shared.pollingInterval
        defer { Settings.shared.pollingInterval = original }

        Settings.shared.pollingInterval = 0.1
        XCTAssertEqual(Settings.shared.refreshSeconds, 1, accuracy: 0.001)
        Settings.shared.pollingInterval = 999
        XCTAssertEqual(Settings.shared.refreshSeconds, 60, accuracy: 0.001)
    }
}
