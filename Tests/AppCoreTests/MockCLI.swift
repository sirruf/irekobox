import Foundation
import ContainerKit
import EngineCore
@testable import AppCore

/// A test double for `ContainerCommanding`: returns canned stdout for reads and
/// records argv for actions. Single-threaded test use → `@unchecked Sendable`.
final class MockCLI: ContainerCommanding, @unchecked Sendable {
    /// Returns canned stdout for a given argv (default: empty JSON array).
    var responder: @Sendable ([String]) -> Data = { _ in Data("[]".utf8) }
    /// If set, `run` throws this.
    var runError: Error?
    /// Recorded action invocations.
    private(set) var runCalls: [[String]] = []

    /// Services always report running, so the store fetches other resources.
    static let runningStatus = Data(#"{"status":"running"}"#.utf8)

    func data(_ arguments: [String]) async throws -> Data {
        if arguments.starts(with: ["system", "status"]) { return Self.runningStatus }
        if arguments.starts(with: ["builder", "status"]) { return Data("[]".utf8) }
        return responder(arguments)
    }

    func decode<T: Decodable & Sendable>(_ type: T.Type, _ arguments: [String],
                                         alsoAccepting exitCodes: Set<Int32>) async throws -> T {
        try JSONDecoder().decode(T.self, from: await data(arguments))
    }

    func run(_ arguments: [String], workingDirectory: URL?) async throws {
        runCalls.append(arguments)
        if let runError { throw runError }
    }

    func run(_ arguments: [String], input: Data, workingDirectory: URL?) async throws {
        runCalls.append(arguments)
        if let runError { throw runError }
    }

    func didRun(_ argv: [String]) -> Bool { runCalls.contains(argv) }

    /// A CLI-backed engine and a store-backed model over this mock.
    @MainActor
    func engineAndModel() -> (CLIEngine, EngineModel) {
        let engine = CLIEngine(cli: self, stream: CLIStream())
        return (engine, EngineModel(source: EngineStore(engine: engine)))
    }
}

enum Fixtures {
    static let images = #"""
    [{"id":"e8","configuration":{"name":"docker.io/library/alpine:latest","descriptor":{"digest":"sha256:e8cab8ec8514","mediaType":"m","size":497}},"variants":[{"size":3868385,"platform":{"architecture":"arm64","os":"linux"}}]}]
    """#

    static let volumes = #"""
    [{"id":"data","configuration":{"driver":"local","format":"ext4","labels":{},"name":"data","options":{},"sizeInBytes":1,"source":"/p/v.img"}}]
    """#

    static let networks = #"""
    [{"id":"default","configuration":{"labels":{"com.apple.container.resource.role":"builtin"},"mode":"nat","name":"default","plugin":"p"},"status":{"ipv4Gateway":"10.0.0.1","ipv4Subnet":"10.0.0.0/24"}},
     {"id":"mynet","configuration":{"labels":{},"mode":"nat","name":"mynet","plugin":"p"},"status":{"ipv4Subnet":"10.1.0.0/24"}}]
    """#

    static let containers = #"""
    [{"id":"web","status":{"networks":[],"state":"running"},"configuration":{"id":"web","image":{"reference":"nginx","descriptor":{"digest":"sha256:x","mediaType":"m","size":1}},"resources":{"cpus":2,"memoryInBytes":1073741824,"cpuOverhead":1},"platform":{"architecture":"arm64","os":"linux"},"networks":[],"initProcess":{"executable":"nginx","arguments":[],"workingDirectory":"/","environment":[]},"labels":{},"creationDate":"2026-06-10T00:00:00Z","readOnly":false,"runtimeHandler":"r","rosetta":false}}]
    """#
}
