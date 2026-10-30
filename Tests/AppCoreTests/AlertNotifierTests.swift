import XCTest
import ContainerKit
import EngineCore
@testable import AppCore

@MainActor
final class AlertNotifierTests: XCTestCase {
    /// Polls come often only while a container is starting or unhealthy, or
    /// alerts just came; otherwise pushed container events ask for a poll.
    func testPollsOftenOnlyWhileSomethingIsInFlux() {
        XCTAssertEqual(AlertNotifier.interval(health: [:], hadAlerts: false), .seconds(15))
        XCTAssertEqual(AlertNotifier.interval(health: ["web": "healthy"], hadAlerts: false), .seconds(15))
        XCTAssertEqual(AlertNotifier.interval(health: ["web": "healthy", "db": "starting"], hadAlerts: false), .seconds(4))
        XCTAssertEqual(AlertNotifier.interval(health: ["db": "unhealthy"], hadAlerts: false), .seconds(4))
        XCTAssertEqual(AlertNotifier.interval(health: [:], hadAlerts: true), .seconds(4))
    }

    func testContainerEventsAskForAPoll() {
        XCTAssertTrue(AlertNotifier.mayAlert(.containerStateChanged(id: "web", from: .running, to: .stopped)))
        XCTAssertTrue(AlertNotifier.mayAlert(.containerRemoved(id: "web")))
        XCTAssertFalse(AlertNotifier.mayAlert(.containerCreated(id: "web")))
        XCTAssertFalse(AlertNotifier.mayAlert(.imageAdded(reference: "nginx")))
        XCTAssertFalse(AlertNotifier.mayAlert(.servicesStarted))
    }
}
