import XCTest
@testable import MigrationKit

final class DesktopMigrationPlanTests: XCTestCase {
    /// A compose service's inspect, trimmed to what the plan reads.
    private func inspect(name: String = "shop-db-1", networkMode: String = "shop_default",
                         mounts: [[String: Any]] = [], host: [String: Any] = [:], running: Bool = true) -> [String: Any] {
        var hostConfig: [String: Any] = ["NetworkMode": networkMode, "PortBindings": ["5432/tcp": [["HostPort": "5432"]]],
                                         "RestartPolicy": ["Name": "unless-stopped"], "Memory": 0]
        hostConfig.merge(host) { $1 }
        return [
            "Id": "abcdef1234567890",
            "Name": "/\(name)",
            "Config": ["Hostname": "abcdef123456", "Image": "postgres:16", "Env": ["POSTGRES_PASSWORD=x"],
                       "Labels": ["com.docker.compose.project": "shop", "com.docker.compose.service": "db"]],
            "HostConfig": hostConfig,
            "State": ["Running": running],
            "Mounts": mounts,
            "NetworkSettings": ["Networks": [networkMode: ["Aliases": ["shop-db-1", "db", "abcdef123456"]]]],
        ]
    }

    private func item(_ inspect: [String: Any], images: [String: String] = ["postgres:16": "image:sha256:p"],
                      exists: @escaping (String) -> Bool = { _ in true }) -> DesktopMigration.Item {
        DesktopMigration.containerItem(inspect, imageItems: images, fileExists: exists)
    }

    private func body(_ item: DesktopMigration.Item) throws -> [String: Any] {
        try XCTUnwrap(item.payload.create?.any as? [String: Any])
    }

    func testComposeServiceKeepsLabelsAliasesVolumesAndNeeds() throws {
        let service = item(inspect(mounts: [
            ["Type": "volume", "Name": "shop_pgdata", "Destination": "/var/lib/postgresql/data", "RW": true],
            ["Type": "bind", "Source": "/Users/me/shop/init.sql", "Destination": "/docker-entrypoint-initdb.d/init.sql", "RW": false],
        ]))
        XCTAssertTrue(service.movable)
        XCTAssertTrue(service.problems.isEmpty, "\(service.problems)")
        XCTAssertEqual(service.needs, ["image:sha256:p", "network:shop_default", "volume:shop_pgdata"])
        XCTAssertEqual(service.payload.wasRunning, true)
        let create = try body(service)
        XCTAssertNil(create["Hostname"], "Docker's short-ID hostname isn't carried over")
        XCTAssertEqual((create["Labels"] as? [String: String])?["com.docker.compose.service"], "db")
        let host = try XCTUnwrap(create["HostConfig"] as? [String: Any])
        XCTAssertEqual(host["Binds"] as? [String], ["shop_pgdata:/var/lib/postgresql/data",
                                                    "/Users/me/shop/init.sql:/docker-entrypoint-initdb.d/init.sql:ro"])
        XCTAssertNil(host["Memory"], "0 means unlimited: left out")
        XCTAssertEqual(host["NetworkMode"] as? String, "shop_default")
        let endpoints = try XCTUnwrap((create["NetworkingConfig"] as? [String: Any])?["EndpointsConfig"] as? [String: Any])
        XCTAssertEqual((endpoints["shop_default"] as? [String: Any])?["Aliases"] as? [String], ["db"])
    }

    func testWhatCantMoveOrMovesWithChanges() {
        let hostNet = item(inspect(networkMode: "host"))
        XCTAssertFalse(hostNet.movable)
        let gpu = item(inspect(host: ["DeviceRequests": [["Count": -1]]]))
        XCTAssertFalse(gpu.movable)
        let missingFolder = item(inspect(mounts: [["Type": "bind", "Source": "/gone", "Destination": "/x", "RW": true]]),
                                 exists: { _ in false })
        XCTAssertFalse(missingFolder.movable)

        let socket = item(inspect(mounts: [["Type": "bind", "Source": "/var/run/docker.sock", "Destination": "/var/run/docker.sock", "RW": true]],
                                  host: ["ExtraHosts": ["host.docker.internal:host-gateway"]]))
        XCTAssertTrue(socket.movable)
        XCTAssertEqual(socket.problems.map(\.level), [.adjusted, .adjusted])
        XCTAssertNil(((try? body(socket))?["HostConfig"] as? [String: Any])?["Binds"])

        let untagged = item(inspect(), images: [:])
        XCTAssertTrue(untagged.problems.contains { $0.text.contains("will be pulled") })
    }

    func testVolumesNetworksImagesAndRegistries() {
        let users = [inspect(name: "a", mounts: [["Type": "volume", "Name": "shared", "Destination": "/d"]]),
                     inspect(name: "b", mounts: [["Type": "volume", "Name": "shared", "Destination": "/d"]])]
        let items = DesktopMigration.plan(
            networks: [["Name": "bridge", "Driver": "bridge"], ["Name": "shop_default", "Driver": "bridge",
                        "IPAM": ["Config": [["Subnet": "172.18.0.0/16"]]], "Labels": ["com.docker.compose.project": "shop"]],
                       ["Name": "swarmnet", "Driver": "overlay"]],
            volumes: [["Name": "shared", "Driver": "local"], ["Name": "nfs", "Driver": "local", "Options": ["type": "nfs"]]],
            volumeSizes: ["shared": 42],
            images: [["Id": "sha256:p", "RepoTags": ["postgres:16", "postgres:latest"], "Size": 400],
                     ["Id": "sha256:d", "RepoTags": ["<none>:<none>"]]],
            containers: users, registries: ["ghcr.io"], fileExists: { _ in true })
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        XCTAssertNil(byID["network:bridge"])
        XCTAssertEqual(byID["network:shop_default"]?.problems.first?.level, .adjusted, "new subnet")
        XCTAssertEqual(byID["network:swarmnet"]?.movable, false)
        XCTAssertEqual(byID["volume:shared"]?.size, 42)
        XCTAssertTrue(byID["volume:shared"]?.problems.first?.text.contains("one running container") == true)
        XCTAssertEqual(byID["volume:nfs"]?.movable, false)
        XCTAssertEqual(byID["image:sha256:p"]?.payload.references, ["postgres:16", "postgres:latest"])
        XCTAssertNil(byID["image:sha256:d"], "untagged images are skipped")
        XCTAssertEqual(byID["registry:ghcr.io"]?.movable, false)
        XCTAssertEqual(DesktopMigrationRunner.order(items).first?.kind, .network)
    }

    func testJSONValueRoundTripsThroughSavedProgress() throws {
        let value = JSONValue(["a": 1, "b": [true, "x"], "c": NSNull(), "d": 1.5] as [String: Any])
        let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
        let any = try XCTUnwrap(decoded.any as? [String: Any])
        XCTAssertEqual(any["a"] as? Int64, 1)
        XCTAssertEqual((any["b"] as? [Any])?.first as? Bool, true)
    }

    func testReferenceSplit() {
        XCTAssertTrue(DesktopMigrationRunner.split("postgres:16") == ("postgres", "16"))
        XCTAssertTrue(DesktopMigrationRunner.split("localhost:5000/app") == ("localhost:5000/app", "latest"))
        XCTAssertTrue(DesktopMigrationRunner.split("ghcr.io/x/y:v1") == ("ghcr.io/x/y", "v1"))
    }

    func testUnixHTTPParsesChunkedAndSizedBodies() throws {
        let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n3\r\n:1}\r\n0\r\n\r\n".utf8)
        XCTAssertEqual(String(decoding: try UnixHTTP.parse(chunked).body, as: UTF8.self), "{\"a\":1}")
        let sized = try UnixHTTP.parse(Data("HTTP/1.1 404 Not Found\r\nContent-Length: 19\r\n\r\n{\"message\":\"nope\"}\n".utf8))
        XCTAssertEqual(sized.status, 404)
        XCTAssertEqual(sized.message, "nope")
    }
}
