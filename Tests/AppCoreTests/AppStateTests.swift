import XCTest
import EngineCore
@testable import AppCore

@MainActor
final class AppStateTests: XCTestCase {
    /// A window opening at launch fetches only what no source has delivered.
    func testLaunchRefreshSkipsWhatTheAgentDelivered() {
        // In-process store: nothing is known yet, so status then disk usage.
        XCTAssertEqual(AppState.launchRefresh(service: .unknown, agentBacked: false, diskUsageLoading: true),
                       [[.system], [.diskUsage]])
        // The agent's subscription already carried the status: don't ask again.
        XCTAssertEqual(AppState.launchRefresh(service: .stopped, agentBacked: true, diskUsageLoading: true),
                       [[.diskUsage]])
        XCTAssertEqual(AppState.launchRefresh(service: .stopped, agentBacked: true, diskUsageLoading: false), [])
        // Connected to an agent that hasn't found out yet: ask.
        XCTAssertEqual(AppState.launchRefresh(service: .unknown, agentBacked: true, diskUsageLoading: false),
                       [[.system]])
    }

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
