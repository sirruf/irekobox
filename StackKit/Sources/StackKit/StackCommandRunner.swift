import Foundation
import ContainerKit

/// Abstraction over executing a `container` argv. Lets ``ComposeRunner`` run
/// against the real CLI in the app and a mock in tests.
///
/// `workingDirectory` is the compose file's folder, so relative build contexts
/// and bind-mount sources resolve correctly.
public protocol StackCommandRunner: Sendable {
    func run(_ arguments: [String], workingDirectory: URL?) async throws
}

/// The real CLI from ContainerKit already exposes the right method.
extension ContainerCLI: StackCommandRunner {}
