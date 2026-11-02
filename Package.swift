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
            path: "KagiPeek/Core/Pure",
            // The pure layer is where the migration has to end up, so it is checked first:
            // a new non-`Sendable` decision type fails here long before it can reach a tap
            // callback. Same setting as the app target's `SWIFT_STRICT_CONCURRENCY`.
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "KagiPeekCoreTests",
            dependencies: ["KagiPeekCore"],
            path: "Tests/KagiPeekCoreTests"
        )
    ]
)
