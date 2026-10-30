import Foundation

/// Abstraction over the `container` CLI used by repositories, so view models /
/// repositories can be unit-tested against a mock instead of the live binary.
/// `ContainerCLI` is the production conformer.
public protocol ContainerCommanding: Sendable {
    func data(_ arguments: [String]) async throws -> Data
    /// `alsoAccepting`: exit codes whose stdout is still a valid answer.
    func decode<T: Decodable & Sendable>(_ type: T.Type, _ arguments: [String],
                                         alsoAccepting exitCodes: Set<Int32>) async throws -> T
    func run(_ arguments: [String], workingDirectory: URL?) async throws
    func run(_ arguments: [String], input: Data, workingDirectory: URL?) async throws
}

public extension ContainerCommanding {
    /// Convenience: only exit code 0 is success.
    func decode<T: Decodable & Sendable>(_ type: T.Type, _ arguments: [String]) async throws -> T {
        try await decode(type, arguments, alsoAccepting: [])
    }

    /// Convenience: run with no working directory.
    func run(_ arguments: [String]) async throws {
        try await run(arguments, workingDirectory: nil)
    }

    /// Convenience: run with stdin and no working directory.
    func run(_ arguments: [String], input: Data) async throws {
        try await run(arguments, input: input, workingDirectory: nil)
    }
}

extension ContainerCLI: ContainerCommanding {}
