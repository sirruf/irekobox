import XCTest
@testable import ContainerKit

/// Decoding tests against JSON captured from the live `container` CLI 1.6.1
/// (`Fixtures/1.6.1`, home path and registry host anonymized).
///
/// Scenario: network `ib-fx-net`, volume `ib-fx-vol`, a running
/// `ib-fx-redis` (`-p 16379:6379 -v ib-fx-vol:/data -l app=fixture`), a stopped
/// `ib-fx-stopped`, and the stopped system `buildkit` container.
final class Fixtures161Tests: XCTestCase {

    private func fixture(_ name: String, ext: String = "json") throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext,
                                                  subdirectory: "Fixtures/1.6.1"))
        return try Data(contentsOf: url)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: fixture(name))
    }

    func testContainerList() throws {
        let containers = try decode([Container].self, "list-all")
        XCTAssertEqual(Set(containers.map(\.id)), ["ib-fx-redis", "ib-fx-stopped", "buildkit"])

        let builder = try XCTUnwrap(containers.first { $0.id == "buildkit" })
        XCTAssertTrue(builder.isSystem)
        XCTAssertFalse(try XCTUnwrap(containers.first { $0.id == "ib-fx-redis" }).isSystem)
    }

    func testRunningContainerInspect() throws {
        let c = try XCTUnwrap(decode([Container].self, "inspect-running").first)
        XCTAssertEqual(c.state, .running)
        XCTAssertEqual(c.ipv4Address, "192.168.66.2")
        XCTAssertEqual(c.status.networks.first?.ipv4Gateway, "192.168.66.1")
        XCTAssertNotNil(c.startedDate)

        let port = try XCTUnwrap(c.configuration.publishedPorts?.first)
        XCTAssertEqual(port.hostPort, 16379)
        XCTAssertEqual(port.containerPort, 6379)
        XCTAssertEqual(port.runSpec, "16379:6379")

        let mount = try XCTUnwrap(c.configuration.mounts?.first)
        XCTAssertEqual(mount.volumeName, "ib-fx-vol")
        XCTAssertEqual(mount.runSpec, "ib-fx-vol:/data")

        XCTAssertEqual(c.configuration.labels["app"], "fixture")
        XCTAssertTrue(c.configuration.initProcess.environment.contains("FOO=bar"))
    }

    func testStoppedContainerHasNoRuntimeInfo() throws {
        let c = try XCTUnwrap(decode([Container].self, "inspect-stopped").first)
        XCTAssertEqual(c.state, .stopped)
        XCTAssertNil(c.ipv4Address)
        XCTAssertNil(c.startedDate)
    }

    func testStats() throws {
        let s = try XCTUnwrap(decode([ContainerStats].self, "stats").first)
        XCTAssertEqual(s.id, "ib-fx-redis")
        XCTAssertEqual(s.memoryLimitBytes, 1_073_741_824)
        XCTAssertEqual(s.numProcesses, 6)
    }

    func testSystemStatus() throws {
        let status = try decode(SystemStatus.self, "system-status")
        XCTAssertTrue(status.isRunning)
        XCTAssertEqual(status.apiServerVersion, "1.6.1")
        XCTAssertEqual(status.apiServerAppName, "container-apiserver")
        XCTAssertEqual(status.clientVersion, "1.6.1")
        XCTAssertEqual(status.appRoot, "/Users/fixture/Library/Application Support/com.apple.container/")
        XCTAssertEqual(status.hostCPUs, 10)
        XCTAssertEqual(status.containersRunning, 1)
    }

    func testDiskUsage() throws {
        let df = try decode(SystemDiskUsage.self, "system-df")
        XCTAssertGreaterThan(df.images.total, 0)
        XCTAssertGreaterThan(df.images.sizeInBytes, 0)
    }

    /// 1.6.1 returns the builder container even when it is stopped; the status
    /// must come from its `status.state`, not from the array being non-empty.
    func testStoppedBuilderIsNotRunning() throws {
        let builder = BuilderStatus.parse(try fixture("builder-status"))
        XCTAssertFalse(builder.isRunning)
        XCTAssertEqual(builder.detail, "buildkit")
    }

    func testRunningBuilderIsRunning() throws {
        let json = #"[{"id":"buildkit","status":{"state":"running","networks":[]}}]"#
        XCTAssertTrue(BuilderStatus.parse(Data(json.utf8)).isRunning)
        XCTAssertFalse(BuilderStatus.parse(Data("[]".utf8)).isRunning)
    }

    func testImages() throws {
        let images = try decode([ContainerImage].self, "image-ls")
        let redis = try XCTUnwrap(images.first { $0.reference == "docker.io/library/redis:7-alpine" })
        XCTAssertEqual(redis.shortName, "redis:7-alpine")
        XCTAssertTrue(redis.architectures.contains("arm64"))
        XCTAssertGreaterThan(redis.totalSize, 0)
        XCTAssertFalse(redis.isSystem)

        // `image ls` also lists what `container` pulls for itself.
        let system = images.filter(\.isSystem).map(\.reference)
        XCTAssertTrue(system.contains { $0.hasPrefix("ghcr.io/apple/containerization/vminit") }, "\(system)")
        XCTAssertTrue(system.contains { $0.hasPrefix("ghcr.io/apple/container-builder-shim/builder") }, "\(system)")
    }

    func testVolumes() throws {
        let volumes = try decode([Volume].self, "volume-ls")
        let vol = try XCTUnwrap(volumes.first { $0.name == "ib-fx-vol" })
        XCTAssertEqual(vol.driver, "local")
        XCTAssertEqual(vol.configuration.format, "ext4")
    }

    func testNetworks() throws {
        let networks = try decode([Network].self, "network-ls")
        let net = try XCTUnwrap(networks.first { $0.name == "ib-fx-net" })
        XCTAssertEqual(net.subnet, "192.168.66.0/24")
        XCTAssertFalse(net.isBuiltin)
        XCTAssertTrue(try XCTUnwrap(networks.first { $0.name == "default" }).isBuiltin)
    }

    func testRegistryLogins() throws {
        let login = try XCTUnwrap(decode([RegistryLogin].self, "registry-ls").first)
        XCTAssertEqual(login.hostname, "registry.example.com")
        XCTAssertEqual(login.username, "registry")
        XCTAssertEqual(login.created, "2026-06-10T13:15:27Z")
    }

    func testImageInspectDetails() throws {
        let details = try XCTUnwrap(decode([ImageDetails].self, "image-inspect").first)
        let native = try XCTUnwrap(details.variant(for: "arm64"))
        XCTAssertEqual(native.platform?.architecture, "arm64")
        XCTAssertNotNil(native.config?.config)
        XCTAssertFalse(native.config?.rootfs?.diff_ids?.isEmpty ?? true)
        XCTAssertFalse(native.config?.history?.isEmpty ?? true)
        XCTAssertTrue(details.variants.contains { $0.platform?.architecture == "unknown" } == false
                      || details.variant(for: "unknown")?.platform?.architecture != "unknown",
                      "attestations are never picked")
    }

    func testMachines() throws {
        let listed = try XCTUnwrap(decode([Machine].self, "machine-list").first)
        XCTAssertEqual(listed.default, true)
        XCTAssertTrue(listed.isRunning)
        XCTAssertNotNil(listed.ipAddress)
        let detail = try XCTUnwrap(decode([Machine].self, "machine-inspect").first)
        XCTAssertEqual(detail.homeMount, "rw")
        XCTAssertEqual(detail.imageShortName, "alpine:latest")
        XCTAssertNotNil(detail.userSetup?.username)
        // The container that runs it is hidden among containers.
        let container = try XCTUnwrap(decode([Container].self, "machine-container").first)
        XCTAssertTrue(container.isMachine && container.isSystem)
        XCTAssertEqual(container.id, detail.containerId)
    }

    func testClusterListTable() throws {
        let text = String(decoding: try fixture("cluster-list", ext: "txt"), as: UTF8.self)
        let clusters = ClusterRepository.parse(text)
        let cluster = try XCTUnwrap(clusters.first)
        XCTAssertEqual(cluster.name, "czk8s")
        XCTAssertTrue(cluster.isRunning)
        XCTAssertEqual(cluster.controlPlane?.cpus, 2)
        XCTAssertEqual(cluster.controlPlane?.memory, "8192 MB")
        XCTAssertNotNil(cluster.controlPlane?.address)
        XCTAssertNil(cluster.controlPlane?.ports)
        let two = ClusterRepository.parse("""
        CLUSTER  NODE        ROLE           STATE    CPUS  MEMORY   ADDR            PORTS
        dev      dev         control-plane  running  2     8192 MB  192.168.66.2    6443
        dev      dev-worker  worker         stopped  2     4096 MB
        """)
        XCTAssertEqual(two.first?.nodes.count, 2)
        XCTAssertEqual(two.first?.isRunning, false)
        XCTAssertEqual(two.first?.controlPlane?.ports, "6443")
    }
}
