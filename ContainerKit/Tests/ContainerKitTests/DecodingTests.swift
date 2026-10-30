import XCTest
@testable import ContainerKit

/// Decoding tests against JSON fixtures captured from the live `container` CLI 1.0.0 (kept as compatibility cases;
/// see Fixtures161Tests for the 1.6.1 captures).
final class DecodingTests: XCTestCase {

    func testDecodeContainerList() throws {
        let data = Fixtures.containerListJSON.data(using: .utf8)!
        let containers = try JSONDecoder().decode([Container].self, from: data)

        XCTAssertEqual(containers.count, 1)
        let c = try XCTUnwrap(containers.first)
        XCTAssertEqual(c.id, "cnt-fixture")
        XCTAssertEqual(c.state, .stopped)
        XCTAssertFalse(c.state.isRunning)
        XCTAssertEqual(c.imageShortName, "alpine:latest")
        XCTAssertEqual(c.cpus, 4)
        XCTAssertEqual(c.memoryInBytes, 1_073_741_824)
        XCTAssertEqual(c.configuration.platform.architecture, "arm64")
        XCTAssertEqual(c.configuration.networks.first?.network, "default")
        XCTAssertEqual(c.configuration.initProcess.executable, "sleep")
    }

    func testUnknownStateFallsBack() throws {
        let json = #"[{"id":"x","status":{"state":"paused","networks":[]},"configuration":{"id":"x","image":{"reference":"alpine","descriptor":{"digest":"sha256:abc","mediaType":"m","size":1}},"resources":{"cpus":1,"memoryInBytes":1,"cpuOverhead":0},"platform":{"architecture":"arm64","os":"linux"},"networks":[],"initProcess":{"executable":"sh","arguments":[],"workingDirectory":"/","environment":[]},"labels":{},"creationDate":"2026-06-10T00:00:00Z","readOnly":false,"runtimeHandler":"r","rosetta":false}}]"#
        let containers = try JSONDecoder().decode([Container].self, from: json.data(using: .utf8)!)
        XCTAssertEqual(containers.first?.state, .unknown("paused"))
    }

    func testDecodeStats() throws {
        let data = Fixtures.statsJSON.data(using: .utf8)!
        let samples = try JSONDecoder().decode([ContainerStats].self, from: data)
        let s = try XCTUnwrap(samples.first)
        XCTAssertEqual(s.id, "cnt-fixture")
        XCTAssertEqual(s.memoryUsageBytes, 2_007_040)
        XCTAssertEqual(s.memoryLimitBytes, 1_073_741_824)
        XCTAssertEqual(s.numProcesses, 1)
        XCTAssertEqual(s.memoryFraction, Double(2_007_040) / Double(1_073_741_824), accuracy: 0.0001)

        // CPU%: +1_500_000 usec of CPU over a 1.5s interval == 100%.
        let later = ContainerStats(id: "x", cpuUsageUsec: s.cpuUsageUsec + 1_500_000,
                                   memoryUsageBytes: 0, memoryLimitBytes: 1, networkRxBytes: 0,
                                   networkTxBytes: 0, blockReadBytes: 0, blockWriteBytes: 0, numProcesses: 1)
        XCTAssertEqual(later.cpuPercent(since: s, interval: 1.5), 100, accuracy: 0.01)
    }

    func testDecodeImage() throws {
        let json = #"""
        [{"id":"e8cab8","configuration":{"creationDate":"2026-06-09T20:11:09Z","name":"docker.io/library/alpine:latest","descriptor":{"digest":"sha256:e8cab8","mediaType":"application/vnd.oci.image.index.v1+json","size":497}},"variants":[{"size":3868385,"platform":{"architecture":"arm64","os":"linux"}},{"size":100,"platform":{"architecture":"unknown","os":"unknown"}}]}]
        """#
        let images = try JSONDecoder().decode([ContainerImage].self, from: json.data(using: .utf8)!)
        let img = try XCTUnwrap(images.first)
        XCTAssertEqual(img.reference, "docker.io/library/alpine:latest")
        XCTAssertEqual(img.shortName, "alpine:latest")
        XCTAssertEqual(img.totalSize, 3868485)
        XCTAssertEqual(img.architectures, ["arm64"])
    }

    func testDecodeVolume() throws {
        let json = #"""
        [{"id":"cz","configuration":{"creationDate":"2026-06-10T11:12:53Z","driver":"local","format":"ext4","labels":{},"name":"cz","options":{},"sizeInBytes":549755813888,"source":"/path/volume.img"}}]
        """#
        let volumes = try JSONDecoder().decode([Volume].self, from: json.data(using: .utf8)!)
        let v = try XCTUnwrap(volumes.first)
        XCTAssertEqual(v.name, "cz")
        XCTAssertEqual(v.driver, "local")
        XCTAssertEqual(v.configuration.format, "ext4")
    }

    func testDecodeNetwork() throws {
        let json = #"""
        [{"id":"default","configuration":{"creationDate":"2026-06-10T09:19:55Z","labels":{"com.apple.container.resource.role":"builtin"},"mode":"nat","name":"default","options":{},"plugin":"container-network-vmnet"},"status":{"ipv4Gateway":"192.168.65.1","ipv4Subnet":"192.168.65.0/24","ipv6Subnet":"fd8b::/64"}}]
        """#
        let networks = try JSONDecoder().decode([Network].self, from: json.data(using: .utf8)!)
        let n = try XCTUnwrap(networks.first)
        XCTAssertEqual(n.name, "default")
        XCTAssertEqual(n.mode, "nat")
        XCTAssertEqual(n.subnet, "192.168.65.0/24")
        XCTAssertTrue(n.isBuiltin)
    }

    private func adjacent(_ args: [String], _ flag: String, _ value: String) -> Bool {
        for i in args.indices.dropLast() where args[i] == flag && args[i + 1] == value { return true }
        return false
    }

    func testRecreateArgumentsRoundTrip() throws {
        let json = #"""
        [{"id":"pg","status":{"networks":[],"state":"running"},"configuration":{"id":"pg","image":{"reference":"pgvector/pgvector:pg16","descriptor":{"digest":"sha256:x","mediaType":"m","size":1}},"resources":{"cpus":4,"memoryInBytes":1073741824,"cpuOverhead":1},"platform":{"architecture":"arm64","os":"linux"},"networks":[{"network":"compose-default","options":{"hostname":"pg","mtu":1280}}],"initProcess":{"executable":"docker-entrypoint.sh","arguments":["postgres"],"workingDirectory":"/","environment":["POSTGRES_PASSWORD=pg"]},"labels":{},"creationDate":"2026-06-10T00:00:00Z","readOnly":false,"runtimeHandler":"r","rosetta":false,"publishedPorts":[{"containerPort":5432,"hostPort":5432,"hostAddress":"0.0.0.0","proto":"tcp"}],"mounts":[{"destination":"/var/lib/postgresql/data","options":[],"source":"/p/volume.img","type":{"volume":{"name":"compose-pg16_data"}}}]}}]
        """#
        let container = try XCTUnwrap(JSONDecoder().decode([Container].self, from: json.data(using: .utf8)!).first)

        let edits = ContainerRecreate.currentEdits(for: container)
        XCTAssertEqual(edits.environment, ["POSTGRES_PASSWORD=pg"])
        XCTAssertEqual(edits.ports, ["5432:5432"])               // 0.0.0.0 + tcp dropped
        XCTAssertEqual(edits.volumes, ["compose-pg16_data:/var/lib/postgresql/data"]) // named, not the .img path
        XCTAssertEqual(edits.networks, ["compose-default"])

        // With the image entrypoint stripped, the command becomes just `postgres`.
        let args = ContainerRecreate.runArguments(for: container, edits: edits,
                                                  imageEntrypoint: ["docker-entrypoint.sh"])
        XCTAssertEqual(Array(args.prefix(4)), ["run", "--detach", "--name", "pg"])
        XCTAssertTrue(adjacent(args, "--network", "compose-default"))
        XCTAssertTrue(adjacent(args, "--env", "POSTGRES_PASSWORD=pg"))
        XCTAssertTrue(adjacent(args, "--publish", "5432:5432"))
        XCTAssertTrue(adjacent(args, "--volume", "compose-pg16_data:/var/lib/postgresql/data"))
        XCTAssertTrue(adjacent(args, "--memory", "1024M"))
        XCTAssertEqual(Array(args.suffix(2)), ["pgvector/pgvector:pg16", "postgres"])
        XCTAssertEqual(args.filter { $0 == "docker-entrypoint.sh" }.count, 0)  // no entrypoint accumulation
    }

    func testParseImageEntrypoint() {
        let json = #"[{"id":"x","configuration":{"name":"pgvector/pgvector:pg16","descriptor":{"digest":"d","mediaType":"m","size":1}},"variants":[{"config":{"architecture":"arm64","config":{"Entrypoint":["docker-entrypoint.sh"],"Cmd":["postgres"]}},"platform":{"architecture":"arm64","os":"linux"},"size":1},{"config":{"architecture":"amd64","config":{"Entrypoint":["other.sh"]}},"platform":{"architecture":"amd64","os":"linux"},"size":1}]}]"#
        let ep = ContainerRecreate.parseEntrypoint(Data(json.utf8), architecture: "arm64")
        XCTAssertEqual(ep, ["docker-entrypoint.sh"])
        XCTAssertEqual(ContainerRecreate.parseEntrypoint(Data("[]".utf8), architecture: "arm64"), [])
    }

    func testBuilderStatusParse() {
        XCTAssertFalse(BuilderStatus.parse(Data("[]".utf8)).isRunning)
        let running = BuilderStatus.parse(Data(#"[{"id":"buildkit","status":{"state":"running"}}]"#.utf8))
        XCTAssertTrue(running.isRunning)
        XCTAssertEqual(running.detail, "buildkit")
        // A builder entry without a running state is not running.
        XCTAssertFalse(BuilderStatus.parse(Data(#"[{"id":"buildkit"}]"#.utf8)).isRunning)
        XCTAssertFalse(BuilderStatus.parse(Data("garbage".utf8)).isRunning)
    }

    func testDecodeSystemDiskUsage() throws {
        let data = Fixtures.systemDfJSON.data(using: .utf8)!
        let df = try JSONDecoder().decode(SystemDiskUsage.self, from: data)
        XCTAssertEqual(df.images.total, 2)
        XCTAssertEqual(df.images.active, 1)
        XCTAssertEqual(df.images.reclaimableInBytes, 240_300_032)
        XCTAssertEqual(df.containers.total, 1)
        XCTAssertEqual(df.volumes.total, 0)
    }
}

/// Raw JSON captured from `container … --format json` on 2026-06-10.
private enum Fixtures {
    static let containerListJSON = #"""
    [{"configuration":{"capAdd":[],"capDrop":[],"creationDate":"2026-06-10T09:38:50Z","dns":{"nameservers":[],"options":[],"searchDomains":[]},"id":"cnt-fixture","image":{"descriptor":{"digest":"sha256:a2d49ea686c2adfe3c992e47dc3b5e7fa6e6b5055609400dc2acaeb241c829f4","mediaType":"application/vnd.oci.image.index.v1+json","size":9218},"reference":"docker.io/library/alpine:latest"},"initProcess":{"arguments":["600"],"environment":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],"executable":"sleep","rlimits":[],"supplementalGroups":[],"terminal":false,"user":{"id":{"gid":0,"uid":0}},"workingDirectory":"/"},"labels":{},"mounts":[],"networks":[{"network":"default","options":{"hostname":"cnt-fixture","mtu":1280}}],"platform":{"architecture":"arm64","os":"linux"},"publishedPorts":[],"publishedSockets":[],"readOnly":false,"resources":{"cpuOverhead":1,"cpus":4,"memoryInBytes":1073741824},"rosetta":false,"runtimeHandler":"container-runtime-linux","ssh":false,"sysctls":{},"useInit":false,"virtualization":false},"id":"cnt-fixture","status":{"networks":[],"state":"stopped"}}]
    """#


    static let statsJSON = #"""
    [{"blockReadBytes":1744896,"blockWriteBytes":0,"cpuUsageUsec":1511,"id":"cnt-fixture","memoryLimitBytes":1073741824,"memoryUsageBytes":2007040,"networkRxBytes":10990,"networkTxBytes":602,"numProcesses":1}]
    """#

    static let systemDfJSON = #"""
    {"containers":{"active":0,"reclaimable":4096,"sizeInBytes":4096,"total":1},"images":{"active":1,"reclaimable":240300032,"sizeInBytes":892960768,"total":2},"volumes":{"active":0,"reclaimable":0,"sizeInBytes":0,"total":0}}
    """#
}
