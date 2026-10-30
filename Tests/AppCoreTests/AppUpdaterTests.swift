import XCTest
@testable import AppCore

final class AppUpdaterTests: XCTestCase {
    private func appcast(build: Int, minimum: String? = nil) -> AppUpdater.Appcast {
        AppUpdater.Appcast(version: "0.2.0", build: build, url: URL(string: "https://example.com/a.zip")!,
                           sha256: "00", notes: nil, minimumSystemVersion: minimum)
    }

    func testNewerBuildsOnSupportedSystems() throws {
        XCTAssertTrue(AppUpdater.isNewer(appcast(build: 5), than: 4))
        XCTAssertFalse(AppUpdater.isNewer(appcast(build: 4), than: 4))
        XCTAssertFalse(AppUpdater.isNewer(appcast(build: 5, minimum: "99.0"), than: 4), "needs a newer macOS")
        XCTAssertTrue(AppUpdater.isNewer(appcast(build: 5, minimum: "26.0"), than: 4))
        let json = #"{"version":"0.2.0","build":7,"url":"https://example.com/C.zip","sha256":"ab","notes":"Fixes"}"#
        XCTAssertEqual(try JSONDecoder().decode(AppUpdater.Appcast.self, from: Data(json.utf8)).build, 7)
    }

    func testChecksumMismatchIsRefusedBeforeUnpacking() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ib-upd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let zip = folder.appending(path: "u.zip")
        try Data("not a zip".utf8).write(to: zip)
        XCTAssertThrowsError(try AppUpdater.prepare(zip: zip, sha256: "00", in: folder)) { error in
            XCTAssertTrue(error.localizedDescription.contains("checksum"))
        }
    }

    func testSignatureCheckTellsOurTeamFromOthers() throws {
        // A system app: valid Apple signature, but not ours.
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        XCTAssertNil(AppUpdater.signatureProblem(finder, requirement: "anchor apple"))
        XCTAssertNotNil(AppUpdater.signatureProblem(finder, requirement: AppUpdater.requirement))
        // Unsigned junk.
        let folder = FileManager.default.temporaryDirectory.appending(path: "ib-fake-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNotNil(AppUpdater.signatureProblem(folder, requirement: "anchor apple generic"))
    }

    /// A real release zip: IREKOBOX_RELEASE_ZIP=build/release/Irekobox-0.1.0.zip IREKOBOX_RELEASE_SHA=<sha256>
    func testReleaseZipIsCheckedEndToEnd() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["IREKOBOX_RELEASE_ZIP"], let sha = env["IREKOBOX_RELEASE_SHA"] else { throw XCTSkip("live only") }
        let folder = FileManager.default.temporaryDirectory.appending(path: "ib-rel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let zip = folder.appending(path: "r.zip")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: zip)
        let notarized = env["IREKOBOX_RELEASE_NOTARIZED"] == "1"
        do {
            let app = try AppUpdater.prepare(zip: zip, sha256: sha, in: folder)
            XCTAssertTrue(notarized, "an un-notarized build must be refused")
            XCTAssertEqual(app.lastPathComponent, "Irekobox.app")
        } catch {
            XCTAssertFalse(notarized, "\(error)")
            XCTAssertTrue(error.localizedDescription.contains("isn't signed by"), error.localizedDescription)
            // Everything but notarization holds.
            let unpacked = folder.appending(path: "unpacked/Irekobox.app")
            let relaxed = AppUpdater.requirement.replacingOccurrences(of: " and notarized", with: "")
            XCTAssertNil(AppUpdater.signatureProblem(unpacked, requirement: relaxed))
        }
    }
}
