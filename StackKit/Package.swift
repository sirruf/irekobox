// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StackKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "StackKit", targets: ["StackKit"]),
    ],
    dependencies: [
        .package(path: "../ComposeKit"),
        .package(path: "../ContainerKit"),
    ],
    targets: [
        .target(
            name: "StackKit",
            dependencies: [
                .product(name: "ComposeKit", package: "ComposeKit"),
                .product(name: "ContainerKit", package: "ContainerKit"),
            ]
        ),
        .testTarget(
            name: "StackKitTests",
            dependencies: ["StackKit"]
        ),
    ]
)
