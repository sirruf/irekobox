import XCTest
import ContainerKit
@testable import AppCore

/// Drives test clusters: IREKOBOX_LIVE_CLUSTERS=1 IREKOBOX_SCRATCH=<dir> swift test --filter ClustersLive
@MainActor
final class ClustersLiveTests: XCTestCase {
    func testClusterLifecycle() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["IREKOBOX_LIVE_CLUSTERS"] == "1", "live only")
        let scratch = try XCTUnwrap(env["IREKOBOX_SCRATCH"])
        let model = ClustersModel(cli: ContainerCLI(), stream: CLIStream())
        await model.refresh()
        let home = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".kube/config").path
        let before = try Data(contentsOf: URL(fileURLWithPath: home))

        let created = await model.create(.init(name: "czk8s2", cpus: 2, memory: "4G",
                                                 kubeconfig: scratch + "/czk8s2.kubeconfig"))
        XCTAssertTrue(created, model.error ?? "")
        XCTAssertEqual(model.clusters.first { $0.name == "czk8s2" }?.isRunning, true)
        print("progress tail:", model.progress.suffix(2))
        await model.load("registry.local/czk8s-hello:1", into: "czk8s2")
        XCTAssertNil(model.error)
        let path = scratch + "/czk8s2-written.kubeconfig"
        await model.writeConfig("czk8s2", to: path)
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).contains("czk8s2"))
        await model.delete("czk8s2")
        XCTAssertTrue(model.clusters.isEmpty, "\(model.clusters)")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: home)), before, "~/.kube/config untouched")
    }
}
