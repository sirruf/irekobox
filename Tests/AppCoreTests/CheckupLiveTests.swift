import XCTest
import ContainerKit
@testable import AppCore

/// Runs the checkup against live ibd-* containers: IREKOBOX_LIVE_CHECKUP=1 swift test --filter CheckupLive
final class CheckupLiveTests: XCTestCase {
    func testLiveContainers() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IREKOBOX_LIVE_CHECKUP"] == "1", "live only")
        let engine = XPCEngine(fallback: CLIEngine())
        let containers = try await engine.listContainers(all: false).filter { $0.id.hasPrefix("ibd-") }
        for container in containers.sorted(by: { $0.id < $1.id }) {
            print("== \(container.id)")
            for finding in await CheckupRunner.run(container, engine: engine) {
                print("  [\(finding.level)] \(finding.title): \(finding.detail)\(finding.fix.map { " → \($0)" } ?? "")")
            }
        }
    }
}
