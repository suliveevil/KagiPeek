// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KagiPeekCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KagiPeekCore", targets: ["KagiPeekCore"])
    ],
    targets: [
        .target(
            name: "KagiPeekCore",
            path: "KagiPeek/Core/Pure"
        ),
        .testTarget(
            name: "KagiPeekCoreTests",
            dependencies: ["KagiPeekCore"],
            path: "Tests/KagiPeekCoreTests"
        )
    ]
)
