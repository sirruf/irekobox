import XCTest
@testable import DockerAPIKit
import ContainerKit

final class CreateMappingTests: XCTestCase {

    private func map(_ json: String, name: String = "web", platform: String? = nil,
                     ports: [Int] = [49153, 49154]) throws -> CreateMapping.Result {
        var free = ports
        let request = try JSONDecoder().decode(CreateRequest.self, from: Data(json.utf8))
        return try CreateMapping.arguments(request, name: name, platform: platform) { free.removeFirst() }
    }

    private func refusal(_ json: String) -> String? {
        do { _ = try map(json); return nil } catch let error as DockerAPIError { return error.message } catch { return "\(error)" }
    }

    func testMinimalRunUsesTheDefaultNetwork() throws {
        let result = try map(#"{"Image":"alpine","Cmd":["echo","hi"]}"#)
        XCTAssertEqual(result.arguments, ["--name", "web", "--network", "default", "alpine", "echo", "hi"])
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testProcessSettingsAndLabels() throws {
        let result = try map(#"""
        {"Image":"nginx:alpine","Env":["A=1","B"],"WorkingDir":"/srv","User":"1000:1000","Tty":true,"OpenStdin":true,
         "Labels":{"com.docker.compose.project":"shop","tier":"web"},
         "Entrypoint":["/bin/sh","-c"],"Cmd":"echo hi"}
        """#, platform: "linux/amd64")
        XCTAssertEqual(result.arguments, [
            "--name", "web", "--platform", "linux/amd64", "-e", "A=1", "-e", "B", "-w", "/srv", "-u", "1000:1000",
            "-t", "-i", "--network", "default",
            "-l", "com.docker.compose.project=shop", "-l", "tier=web",
            "--entrypoint", "/bin/sh", "nginx:alpine", "-c", "echo hi",
        ])
    }

    func testPortsIncludingAutoAssignedHostPorts() throws {
        let result = try map(#"""
        {"Image":"redis","ExposedPorts":{"6379/tcp":{},"9121/tcp":{}},
         "HostConfig":{"PortBindings":{"6379/tcp":[{"HostIp":"127.0.0.1","HostPort":"16379"}],"53/udp":[{"HostPort":""}]},
                       "PublishAllPorts":true}}
        """#)
        let ports = result.arguments.enumerated().filter { $0.offset > 0 && result.arguments[$0.offset - 1] == "-p" }.map(\.element)
        XCTAssertEqual(ports, ["49153:53/udp", "127.0.0.1:16379:6379", "49154:9121"])
    }

    func testMountsVolumesAndTmpfs() throws {
        let result = try map(#"""
        {"Image":"postgres","Volumes":{"/var/lib/postgresql/data":{},"/scratch":{}},
         "HostConfig":{"Binds":["/Users/me/init:/docker-entrypoint-initdb.d:ro,z","pgdata:/backup"],
                       "Mounts":[{"Type":"volume","Source":"cache","Target":"/cache","ReadOnly":true},
                                 {"Type":"tmpfs","Target":"/run"},
                                 {"Type":"volume","Target":"/var/lib/postgresql/data"}],
                       "Tmpfs":{"/tmp":"size=64m"}}}
        """#)
        let args = result.arguments
        XCTAssertTrue(args.contains("/Users/me/init:/docker-entrypoint-initdb.d:ro"))
        XCTAssertTrue(args.contains("pgdata:/backup"))
        XCTAssertTrue(args.contains("type=volume,source=cache,target=/cache,readonly"))
        XCTAssertTrue(args.contains("/run") && args.contains("/tmp"))
        // The data path is mounted by an anonymous volume once, /scratch gets its own.
        XCTAssertEqual(result.anonymousVolumes.map(\.path), ["/var/lib/postgresql/data", "/scratch"])
        XCTAssertTrue(result.anonymousVolumes.allSatisfy { $0.name.hasPrefix("web-anon-") })
        let label = args.first { $0.hasPrefix("\(DockerLabels.anonymousVolumes)=") }
        XCTAssertEqual(label?.split(separator: "=").last?.split(separator: ",").count, 2)
    }

    func testSingleFileBindMountsUseVolumeSyntax() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ib-binds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let secret = folder.appending(path: "password.txt").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: secret))
        let result = try map("""
        {"Image":"mysql","HostConfig":{"Mounts":[
          {"Type":"bind","Source":"\(secret)","Target":"/run/secrets/db-password","ReadOnly":true},
          {"Type":"bind","Source":"\(folder.path)","Target":"/data"}]}}
        """)
        XCTAssertTrue(result.arguments.contains("\(secret):/run/secrets/db-password:ro"), "a file goes through -v")
        XCTAssertTrue(result.arguments.contains("type=bind,source=\(folder.path),target=/data"), "a folder keeps --mount")
    }

    func testVolumeSyncModesGoWithTheirMounts() throws {
        let request = try JSONDecoder().decode(CreateRequest.self, from: Data(#"""
        {"Image":"postgres","HostConfig":{"Binds":["pgdata:/var/lib/postgresql/data","wal:/wal:ro","/Users/me/x:/x"],
          "Mounts":[{"Type":"volume","Source":"cache","Target":"/cache","ReadOnly":true},
                    {"Type":"volume","Source":"plain","Target":"/plain"}]}}
        """#.utf8))
        let result = try CreateMapping.arguments(request, name: "db", platform: nil,
                                                 volumeSync: ["pgdata": "nosync", "wal": "full", "cache": "nosync"]) { 49153 }
        let args = result.arguments
        XCTAssertTrue(args.contains("pgdata:/var/lib/postgresql/data:sync=nosync"))
        XCTAssertTrue(args.contains("wal:/wal:ro,sync=full"))
        XCTAssertTrue(args.contains("/Users/me/x:/x"), "bind mounts have no sync mode")
        XCTAssertTrue(args.contains("type=volume,source=cache,target=/cache,sync=nosync,readonly"))
        XCTAssertTrue(args.contains("type=volume,source=plain,target=/plain"))
    }

    func testANameTooLongForTheRuntimeIsCutAndKept() throws {
        let long = "reaper_" + String(repeating: "d92abc88", count: 8)
        let result = try map(#"{"Image":"testcontainers/ryuk"}"#, name: long)
        let runtime = result.arguments[1]
        XCTAssertEqual(runtime.count, 63)
        XCTAssertTrue(runtime.hasPrefix(String(long.prefix(54)) + "-"))
        XCTAssertTrue(ContainerNames.isValid(runtime))
        XCTAssertNotEqual(runtime, ContainerNames.runtimeName(for: long + "x"), "the hash tells similar names apart")
        XCTAssertTrue(result.arguments.contains("\(DockerLabels.name)=\(long)"))
        XCTAssertEqual(try map(#"{"Image":"x"}"#, name: String(repeating: "a", count: 63)).arguments[1].count, 63)
        XCTAssertFalse(try map(#"{"Image":"x"}"#).arguments.contains { $0.hasPrefix(DockerLabels.name) })
    }

    func testTheDockerSocketIsOurs() throws {
        // Testcontainers' Ryuk mounts the client's socket; compose files often
        // a Binds entry. Either way the container gets our API.
        let request = try JSONDecoder().decode(CreateRequest.self, from: Data(#"""
        {"Image":"testcontainers/ryuk","HostConfig":{
          "Binds":["/Users/me/.docker/run/docker.sock:/var/run/docker.sock:rw"],
          "Mounts":[{"Type":"bind","Source":"/var/run/docker.sock","Target":"/var/run/docker.sock","ReadOnly":true}]}}
        """#.utf8))
        let socket = "/Users/me/.irekobox/docker.sock"
        let result = try CreateMapping.arguments(request, name: "ryuk", platform: nil, dockerSocket: socket) { 49153 }
        let volumes = result.arguments.enumerated().filter { $0.offset > 0 && result.arguments[$0.offset - 1] == "-v" }.map(\.element)
        XCTAssertEqual(volumes, ["\(socket):/var/run/docker.sock", "\(socket):/var/run/docker.sock"])
        XCTAssertTrue(result.anonymousVolumes.isEmpty)
        XCTAssertThrowsError(try map(#"{"Image":"x","HostConfig":{"Binds":["/var/run/docker.sock:/var/run/docker.sock"]}}"#))
    }

    func testNetworksWithAliases() throws {
        let result = try map(#"""
        {"Image":"app","HostConfig":{"NetworkMode":"shop_default"},
         "NetworkingConfig":{"EndpointsConfig":{"shop_default":{"Aliases":["web","api"]},"backend":{"Aliases":["app"],"MacAddress":"02:42:ac:11:00:02"}}}}
        """#)
        let networks = result.arguments.enumerated().filter { $0.offset > 0 && result.arguments[$0.offset - 1] == "--network" }.map(\.element)
        XCTAssertEqual(networks, ["shop_default", "backend,mac=02:42:ac:11:00:02"], "aliases aren't given to the runtime")
        XCTAssertTrue(result.arguments.contains(#"\#(DockerLabels.aliases)={"backend":["app"],"shop_default":["api"]}"#),
                      "the container's own name is not repeated as an alias")

        let none = try map(#"{"Image":"app","HostConfig":{"NetworkMode":"none"}}"#)
        XCTAssertEqual(none.arguments.filter { $0 == "--network" }.count, 1)
        XCTAssertTrue(none.arguments.contains("none"))
    }

    func testResourcesRoundUp() throws {
        let result = try map(#"{"Image":"x","HostConfig":{"Memory":314572801,"NanoCpus":1500000000,"ShmSize":67108864,"CpuShares":512}}"#)
        XCTAssertTrue(result.arguments.contains("301M"))
        XCTAssertEqual(result.arguments[result.arguments.firstIndex(of: "-c")! + 1], "2")
        XCTAssertTrue(result.arguments.contains("64M"))
        XCTAssertEqual(result.warnings.count, 1, "CpuShares warns, doesn't fail")
    }

    func testSettingsWithoutAFlagBecomeLabelsWithAWarning() throws {
        let result = try map(#"""
        {"Image":"x","StopSignal":"SIGQUIT","StopTimeout":20,
         "Healthcheck":{"Test":["CMD","pg_isready"],"Interval":5000000000,"Retries":5},
         "HostConfig":{"RestartPolicy":{"Name":"on-failure","MaximumRetryCount":3},"AutoRemove":true,"Init":true,
                       "CapAdd":["NET_ADMIN"],"ReadonlyRootfs":true,"Ulimits":[{"Name":"nofile","Soft":1024,"Hard":2048}]}}
        """#)
        let args = result.arguments
        XCTAssertTrue(args.contains("\(DockerLabels.restartPolicy)=on-failure:3"))
        XCTAssertTrue(args.contains("\(DockerLabels.stopSignal)=SIGQUIT"))
        XCTAssertTrue(args.contains("\(DockerLabels.stopTimeout)=20"))
        XCTAssertTrue(args.contains { $0.hasPrefix("\(DockerLabels.healthcheck)={") && $0.contains("pg_isready") })
        XCTAssertTrue(args.contains("--rm") && args.contains("--init") && args.contains("--read-only"))
        XCTAssertTrue(args.contains("nofile=1024:2048"))
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("on-failure"))
    }

    func testRefusesWhatAVMCannotDoByFieldName() {
        XCTAssertTrue(refusal(#"{"Image":"x","HostConfig":{"Devices":[{"PathOnHost":"/dev/x"}]}}"#)?.hasPrefix("HostConfig.Devices") == true)
        XCTAssertTrue(refusal(#"{"Image":"x","HostConfig":{"DeviceRequests":[{"Count":-1}]}}"#)?.hasPrefix("HostConfig.DeviceRequests") == true)
        XCTAssertTrue(refusal(#"{"Image":"x","HostConfig":{"ExtraHosts":["a:1.2.3.4"]}}"#)?.hasPrefix("HostConfig.ExtraHosts") == true)
        XCTAssertTrue(refusal(#"{"Image":"x","HostConfig":{"NetworkMode":"host"}}"#)?.contains("host") == true)
        XCTAssertTrue(refusal(#"{"Image":"x","HostConfig":{"NetworkMode":"container:db"}}"#)?.contains("container:db") == true)
        XCTAssertNotNil(refusal(#"{"Cmd":["x"]}"#), "an image is required")
        XCTAssertNotNil(refusal(#"{"Image":"x","HostConfig":{"PortBindings":{"abc/tcp":[]}}}"#))
        XCTAssertNil(refusal(#"{"Image":"x","HostConfig":{"PidMode":"","IpcMode":"private","Privileged":false,"Devices":[]}}"#),
                     "defaults are fine")
    }

    func testImageReferenceNormalization() {
        XCTAssertEqual(ImageReference("alpine")?.canonical, "docker.io/library/alpine:latest")
        XCTAssertEqual(ImageReference("redis:7-alpine")?.familiar, "redis:7-alpine")
        XCTAssertEqual(ImageReference("me/app:1")?.canonical, "docker.io/me/app:1")
        XCTAssertEqual(ImageReference("ghcr.io/apple/x")?.canonical, "ghcr.io/apple/x:latest")
        XCTAssertEqual(ImageReference("localhost:5000/tool:dev")?.registry, "localhost:5000")
        XCTAssertEqual(ImageReference("docker.io/library/nginx:alpine")?.familiar, "nginx:alpine")
        XCTAssertEqual(ImageReference("alpine@sha256:abc")?.canonical, "docker.io/library/alpine@sha256:abc")
        XCTAssertNil(ImageReference("bad name"))
        XCTAssertTrue(ContainerNames.isValid("ib-web_1.a"))
        XCTAssertFalse(ContainerNames.isValid("-web"))
        XCTAssertTrue(ContainerNames.isValid(ContainerNames.random()))
    }

    func testPrivilegedGetsEveryCapabilityInsideItsVM() throws {
        let args = try map(#"{"Image":"x","HostConfig":{"Privileged":true,"CapAdd":["NET_ADMIN"]}}"#).arguments
        XCTAssertNil(refusal(#"{"Image":"x","HostConfig":{"Privileged":true}}"#))
        let index = try XCTUnwrap(args.firstIndex(of: "--cap-add"))
        XCTAssertEqual(args[index + 1], "ALL")
        XCTAssertEqual(args.filter { $0 == "--cap-add" }.count, 1)
    }

    func testHostPortZeroMeansAnyFreePort() throws {
        let result = try map(#"{"Image":"redis","ExposedPorts":{"6379/tcp":{}},"HostConfig":{"PortBindings":{"6379/tcp":[{"HostPort":"0"}]}}}"#)
        XCTAssertTrue(result.arguments.contains("49153:6379"), "\(result.arguments)")
    }

    func testServiceDNSNameGoesOnTheFirstNetwork() throws {
        var free = [1]
        let request = try JSONDecoder().decode(CreateRequest.self, from: Data(#"{"Image":"x","HostConfig":{"NetworkMode":"shop_default"},"NetworkingConfig":{"EndpointsConfig":{"shop_default":{"Aliases":["web"]},"shop_back":{}}}}"#.utf8))
        let result = try CreateMapping.arguments(request, name: "shop-web-1", platform: nil, dnsName: "web.shop.test") { free.removeFirst() }
        let networks = result.arguments.enumerated().filter { $0.offset > 0 && result.arguments[$0.offset - 1] == "--network" }.map(\.element)
        XCTAssertEqual(networks, ["shop_default,alias=web.shop.test", "shop_back"])
    }
}
