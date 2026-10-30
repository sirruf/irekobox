import Foundation

/// Which binary a migration command targets.
public enum MigrationTool: String, Sendable, Hashable {
    case docker
    case container
}

/// One command in a migration plan (binary + argv + human summary).
public struct MigrationCommand: Sendable, Hashable, Identifiable {
    public let id = UUID()
    public let tool: MigrationTool
    public let arguments: [String]
    public let summary: String

    public init(tool: MigrationTool, arguments: [String], summary: String) {
        self.tool = tool
        self.arguments = arguments
        self.summary = summary
    }

    public var displayCommand: String {
        ([tool.rawValue] + arguments).joined(separator: " ")
    }
}

/// Plans importing a Docker image into `container` via a temp tar:
/// `docker save <image> -o tar` → `container image load -i tar`.
/// Pure; the app executes the steps and cleans up the tar.
public struct DockerImageImport: Sendable {
    public init() {}

    public func plan(image: String, tarPath: String) -> [MigrationCommand] {
        [
            MigrationCommand(tool: .docker,
                             arguments: ["save", image, "-o", tarPath],
                             summary: String(localized: "Export \(image) from Docker")),
            MigrationCommand(tool: .container,
                             arguments: ["image", "load", "-i", tarPath],
                             summary: String(localized: "Load \(image) into container")),
        ]
    }
}
