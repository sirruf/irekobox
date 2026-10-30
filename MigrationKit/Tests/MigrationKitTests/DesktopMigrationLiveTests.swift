import XCTest
@testable import MigrationKit

/// Moves ibm-* test resources from a running Docker Desktop to a
/// Irekobox socket, checks them and removes them on both sides:
///   IREKOBOX_LIVE_MIGRATION=1 IREKOBOX_DEST=/path/docker.sock swift test --filter DesktopMigrationLive
final class DesktopMigrationLiveTests: XCTestCase {
    let docker = "/usr/local/bin/docker"
    var destination: String { ProcessInfo.processInfo.environment["IREKOBOX_DEST"] ?? "" }
    let source = DesktopMigration.defaultSourceSocket

    @discardableResult
    func run(_ socket: String, _ arguments: [String], input: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: docker)
        process.arguments = ["--host", "unix://\(socket)"] + arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        if let input {
            let pipe = Pipe()
            process.standardInput = pipe
            try process.run()
            pipe.fileHandleForWriting.write(Data(input.utf8))
            try pipe.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cleanup() throws {
        for socket in [source, destination] {
            try run(socket, ["rm", "-f", "ibm-app"])
            try run(socket, ["volume", "rm", "-f", "ibm-vol"])
            try run(socket, ["network", "rm", "ibm-net"])
            try run(socket, ["rmi", "ibm-img:1", "ibm-img:2"])
        }
    }

    func testMoveTestResources() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IREKOBOX_LIVE_MIGRATION"] == "1" && !destination.isEmpty, "live only")
        try cleanup()
        defer { try? cleanup() }
        // In Docker Desktop: a network, a volume with data, an image with two
        // tags, and a running redis on them.
        try run(source, ["network", "create", "--label", "czm=1", "ibm-net"])
        try run(source, ["volume", "create", "--label", "czm=1", "ibm-vol"])
        try run(source, ["run", "--rm", "-v", "ibm-vol:/data", "alpine:latest", "sh", "-c",
                         "mkdir -p /data/sub && echo moved > /data/sub/file && dd if=/dev/urandom of=/data/blob bs=1M count=8 2>/dev/null && md5sum /data/blob > /data/blob.md5"])
        try run(source, ["tag", "alpine:latest", "ibm-img:1"])
        try run(source, ["tag", "alpine:latest", "ibm-img:2"])
        try run(source, ["run", "-d", "--name", "ibm-app", "--network", "ibm-net", "--network-alias", "cache",
                         "-v", "ibm-vol:/data", "-p", "16399:6379", "--label", "com.docker.compose.project=czm",
                         "--restart", "unless-stopped", "redis:7-alpine"])

        let inventory = try await DesktopMigration.scan(source: UnixHTTP(socketPath: source))
        let selected = inventory.items.filter { $0.name.hasPrefix("ibm-") }
        XCTAssertEqual(Set(selected.map(\.kind)), [.network, .volume, .container])
        let tagged = try XCTUnwrap(inventory.items.first { $0.payload.references?.contains("ibm-img:2") == true })
        let app = try XCTUnwrap(selected.first { $0.kind == .container })
        XCTAssertTrue(app.needs.contains("volume:ibm-vol") && app.needs.contains("network:ibm-net"), "\(app.needs)")

        let progress = FileManager.default.temporaryDirectory.appending(path: "ibm-progress-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: progress) }
        let runner = DesktopMigrationRunner(source: source, destination: destination, docker: docker, progressFile: progress)
        // The container alone: its volume, network and image come along.
        // (The image with the ibm-img tags is alpine's: moved with all its tags.)
        await runner.run([app, tagged], all: inventory.items, options: .init())
        let statuses = await runner.statuses()
        for (id, status) in statuses { XCTAssertEqual(status, .done, id) }
        XCTAssertEqual(statuses.count, 5, "\(statuses)")
        XCTAssertEqual(try run(source, ["inspect", "-f", "{{.State.Running}}", "ibm-app"]), "false", "handed over")

        XCTAssertEqual(try run(destination, ["inspect", "-f", "{{.State.Running}} {{.HostConfig.RestartPolicy.Name}} {{index .Config.Labels \"com.docker.compose.project\"}}", "ibm-app"]),
                       "true unless-stopped czm")
        // A volume is one VM's disk at a time: stop the app to look inside.
        try run(destination, ["stop", "-t", "1", "ibm-app"])
        XCTAssertEqual(try run(destination, ["run", "--rm", "-v", "ibm-vol:/data", "alpine:latest", "sh", "-c",
                                             "cat /data/sub/file && cd /data && md5sum -c blob.md5 >/dev/null && echo intact"]),
                       "moved\nintact")
        XCTAssertTrue(try run(destination, ["network", "ls", "--format", "{{.Name}}"]).contains("ibm-net"))
        XCTAssertTrue(try run(destination, ["images", "--format", "{{.Repository}}:{{.Tag}}"]).contains("ibm-img:2"))

        // A second run continues: nothing left to do.
        await runner.run([app, tagged], all: inventory.items, options: .init())
        let again = await runner.statuses()
        XCTAssertEqual(again, statuses)
    }
}
