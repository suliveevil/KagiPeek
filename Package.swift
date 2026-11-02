// swift-tools-version: 6.0
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
            path: "KagiPeek/Core/Pure",
            // The pure layer is where the migration ends up, so it is checked first: a new
            // non-`Sendable` decision type fails here long before it can reach a tap
            // callback. Swift 6 language mode + `complete` matches both app build paths.
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "KagiPeekCoreTests",
            dependencies: ["KagiPeekCore"],
            path: "Tests/KagiPeekCoreTests"
        )
    ]
)
