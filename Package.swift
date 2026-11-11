// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WarpNest",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "WarpNestCore",
            targets: ["WarpNestCore"]
        ),
        .executable(
            name: "WarpNest",
            targets: ["WarpNest"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "WarpNestCore",
            dependencies: [],
            path: "Sources/WarpNestCore"
        ),
        .executableTarget(
            name: "WarpNest",
            dependencies: ["WarpNestCore"],
            path: "Sources/WarpNest"
        ),
        .testTarget(
            name: "WarpNestCoreTests",
            dependencies: ["WarpNestCore"],
            path: "Tests/WarpNestCoreTests"
        )
    ]
)
