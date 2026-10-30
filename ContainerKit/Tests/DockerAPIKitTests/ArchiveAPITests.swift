import XCTest
@testable import DockerAPIKit

final class ArchiveAPITests: XCTestCase {

    func testGoFileModeAsTheDockerCLIReadsIt() {
        XCTAssertEqual(ArchiveAPI.goFileMode(0o100644), 0o644)
        XCTAssertEqual(ArchiveAPI.goFileMode(0o040755), (1 << 31) | 0o755)
        XCTAssertEqual(ArchiveAPI.goFileMode(0o120777), (1 << 27) | 0o777)
        XCTAssertEqual(ArchiveAPI.goFileMode(0o104755), (1 << 23) | 0o755, "setuid")
        XCTAssertEqual(ArchiveAPI.goFileMode(0o041777), (1 << 31) | (1 << 20) | 0o777, "sticky dir")
    }

    func testStatHeaderIsBase64JSON() throws {
        let stat = ArchiveAPI.PathStat(name: "hosts", size: 12, mode: 0o644, mtime: "2026-10-26T00:00:00Z", linkTarget: "")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: stat.header))) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "hosts")
        XCTAssertEqual(json["mode"] as? Int, 0o644)
        XCTAssertFalse(stat.isDirectory)
    }

    func testParsesBusyboxPS() {
        let top = ArchiveAPI.parsePS("""
        PID   USER     TIME  COMMAND
            1 root      0:00 nginx: master process nginx -g daemon off;
           30 nginx     0:00 nginx: worker process
        """)
        XCTAssertEqual(top.Titles, ["PID", "USER", "TIME", "COMMAND"])
        XCTAssertEqual(top.Processes.first, ["1", "root", "0:00", "nginx: master process nginx -g daemon off;"])
        XCTAssertEqual(top.Processes.count, 2)
    }

    func testTarRoundTripWithoutMacMetadata() async throws {
        let source = FileManager.default.temporaryDirectory.appending(path: "ib-tar-src-\(UUID().uuidString)")
        let target = FileManager.default.temporaryDirectory.appending(path: "ib-tar-dst-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createDirectory(at: source.appending(path: "conf/sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: source.appending(path: "conf/sub/a.txt"))

        var archive = Data()
        for try await chunk in Tar.create(entry: "conf", in: source, done: {}) { archive.append(chunk) }
        try await Tar.extract(archive, into: target)
        XCTAssertEqual(try String(contentsOf: target.appending(path: "conf/sub/a.txt"), encoding: .utf8), "hello")
        let everything = FileManager.default.enumerator(atPath: target.path)?.allObjects as? [String] ?? []
        XCTAssertFalse(everything.contains { ($0 as NSString).lastPathComponent.hasPrefix("._") }, "\(everything)")
    }

    func testRefusesPathsOutsideTheFolder() async throws {
        // A tar whose entry climbs out with "../": bsdtar refuses it.
        let work = FileManager.default.temporaryDirectory.appending(path: "ib-tar-evil-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work.appending(path: "in/inner"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: work.appending(path: "in/escape.txt"))
        let maker = Process()
        maker.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        maker.currentDirectoryURL = work.appending(path: "in/inner")
        maker.arguments = ["-c", "-f", work.appending(path: "evil.tar").path, "-P", "../escape.txt"]
        let made = AsyncStream<Void> { continuation in maker.terminationHandler = { _ in continuation.finish() } }
        try maker.run()
        for await _ in made {}
        let target = work.appending(path: "out")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try? await Tar.extract(try Data(contentsOf: work.appending(path: "evil.tar")), into: target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appending(path: "escape.txt").path))
    }
}

final class PendingCopiesTests: XCTestCase {
    func testCreatedContainersTakeStandardDirectoriesAndTrailingSlashesAsDirectories() throws {
        XCTAssertEqual(try ArchiveAPI.assumedStat("/etc", in: "web").isDirectory, true)
        XCTAssertEqual(try ArchiveAPI.assumedStat("/", in: "web").name, "/")
        XCTAssertEqual(try ArchiveAPI.assumedStat("/app/config/", in: "web").name, "config")
        XCTAssertThrowsError(try ArchiveAPI.assumedStat("/etc/app.conf", in: "web"),
                             "unknown paths are missing, so the CLI copies to a new name") { error in
            XCTAssertEqual((error as? DockerAPIError)?.status, 404)
        }
    }
}
