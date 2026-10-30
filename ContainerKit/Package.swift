// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ContainerKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ContainerKit", targets: ["ContainerKit"]),
        .library(name: "EngineCore", targets: ["EngineCore"]),
        .library(name: "DockerAPIKit", targets: ["DockerAPIKit"]),
        .library(name: "MCPKit", targets: ["MCPKit"]),
    ],
    targets: [
        .target(name: "ContainerKit"),
        // UI-free engine state: polling, snapshots, events. Hosted by the app
        // today and by the background agent later.
        .target(name: "EngineCore", dependencies: ["ContainerKit"]),
        // Docker Engine API on a Unix socket: own HTTP/1.1 server (decision D2).
        .target(name: "DockerAPIKit", dependencies: ["ContainerKit"]),
        // Model Context Protocol server for AI assistants: tools, access levels, client configs.
        .target(name: "MCPKit", dependencies: ["ContainerKit"]),
        // Development only (not shipped): the API against the live engine.
        .executableTarget(name: "DockerAPIDev", dependencies: ["ContainerKit", "DockerAPIKit"]),
        .testTarget(
            name: "ContainerKitTests",
            dependencies: ["ContainerKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MCPKitTests",
            dependencies: ["MCPKit"]
        ),
        .testTarget(
            name: "EngineCoreTests",
            dependencies: ["EngineCore"]
        ),
        .testTarget(
            name: "DockerAPIKitTests",
            dependencies: ["DockerAPIKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
