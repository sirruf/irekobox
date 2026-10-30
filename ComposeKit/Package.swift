// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ComposeKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ComposeKit", targets: ["ComposeKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "ComposeKit",
            dependencies: ["Yams"]
        ),
        .testTarget(
            name: "ComposeKitTests",
            dependencies: ["ComposeKit"]
        ),
    ]
)
