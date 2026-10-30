// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MigrationKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MigrationKit", targets: ["MigrationKit"]),
    ],
    targets: [
        .target(name: "MigrationKit"),
        .testTarget(
            name: "MigrationKitTests",
            dependencies: ["MigrationKit"]
        ),
    ]
)
