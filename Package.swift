// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Irekobox",
    platforms: [.macOS(.v26)],
    products: [
        // Exposed so the Xcode app target (see project.yml) can link it.
        .library(name: "AppCore", targets: ["AppCore"]),
    ],
    dependencies: [
        .package(path: "ContainerKit"),
        .package(path: "ComposeKit"),
        .package(path: "StackKit"),
        .package(path: "MigrationKit"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        // Already used by ComposeKit; AppCore reads kubeconfig files with it.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        // All UI + view-model logic lives here so it can be unit-tested.
        .target(
            name: "AppCore",
            dependencies: [
                .product(name: "ContainerKit", package: "ContainerKit"),
                .product(name: "EngineCore", package: "ContainerKit"),
                .product(name: "MCPKit", package: "ContainerKit"),
                .product(name: "ComposeKit", package: "ComposeKit"),
                .product(name: "StackKit", package: "StackKit"),
                .product(name: "MigrationKit", package: "MigrationKit"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        // Thin entry point: just the @main App.
        .executableTarget(
            name: "Irekobox",
            dependencies: ["AppCore"]
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: ["AppCore"]
        ),
    ]
)
