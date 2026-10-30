import XCTest
@testable import MigrationKit

/// Read-only scan of a running Docker Desktop: IREKOBOX_LIVE_DESKTOP=1 swift test --filter DesktopScanLive
final class DesktopScanLiveTests: XCTestCase {
    func testScanPrintsTheReport() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IREKOBOX_LIVE_DESKTOP"] == "1", "live only")
        let config = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".docker/config.json")
        let inventory = try await DesktopMigration.scan(source: UnixHTTP(socketPath: DesktopMigration.defaultSourceSocket),
                                                         dockerConfig: config)
        print("Docker Desktop \(inventory.sourceVersion)")
        for item in inventory.items {
            let size = item.size.map { " \($0 / 1_000_000) MB" } ?? ""
            print("[\(item.kind.rawValue)] \(item.name) — \(item.detail)\(size) needs=\(item.needs.count)")
            for problem in item.problems { print("    \(problem.level.rawValue): \(problem.text)") }
        }
        XCTAssertFalse(inventory.items.isEmpty)
    }
}
