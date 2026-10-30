import XCTest
import Yams
@testable import AppCore

final class KubeconfigTests: XCTestCase {
    private let cluster = """
    apiVersion: v1
    kind: Config
    clusters:
    - name: dev
      cluster: {server: "https://192.168.64.5:6443"}
    users:
    - name: dev
      user: {token: abc}
    contexts:
    - name: dev
      context: {cluster: dev, user: dev}
    current-context: dev
    """

    private let base = """
    apiVersion: v1
    kind: Config
    clusters:
    - name: dev
      cluster: {server: "https://elsewhere:6443"}
    users:
    - name: dev
      user: {token: other}
    contexts:
    - name: dev
      context: {cluster: dev, user: dev}
    current-context: dev
    """

    private func load(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(Yams.load(yaml: text) as? [String: Any])
    }

    func testAddsRenamedContextAndKeepsTheRest() throws {
        let merged = try load(Kubeconfig.merge("dev", file: cluster, into: base))
        XCTAssertEqual(merged["current-context"] as? String, "dev")
        let contexts = try XCTUnwrap(merged["contexts"] as? [[String: Any]])
        XCTAssertEqual(contexts.compactMap { $0["name"] as? String }.sorted(), ["dev", "irekobox-dev"])
        let added = try XCTUnwrap(contexts.first { $0["name"] as? String == "irekobox-dev" }?["context"] as? [String: Any])
        XCTAssertEqual(added["cluster"] as? String, "irekobox-dev")
        XCTAssertEqual(added["user"] as? String, "irekobox-dev")
        let clusters = try XCTUnwrap(merged["clusters"] as? [[String: Any]])
        let original = clusters.first { $0["name"] as? String == "dev" }?["cluster"] as? [String: Any]
        XCTAssertEqual(original?["server"] as? String, "https://elsewhere:6443")
    }

    func testAddingAgainReplaces() throws {
        let once = try Kubeconfig.merge("dev", file: cluster, into: base)
        let twice = try load(Kubeconfig.merge("dev", file: cluster, into: once))
        XCTAssertEqual((twice["contexts"] as? [[String: Any]])?.count, 2)
    }

    func testEmptyDefaultFileGetsTheContextAsCurrent() throws {
        let merged = try load(Kubeconfig.merge("dev", file: cluster, into: ""))
        XCTAssertEqual(merged["current-context"] as? String, "irekobox-dev")
    }
}
