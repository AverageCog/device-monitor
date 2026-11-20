// swift-tools-version: 6.0
import PackageDescription

// Everything in the iOS app that is not a SwiftUI view. Builds for macOS too, so its tests run
// with `swift test` on a Mac without booting a simulator.
let package = Package(
    name: "DMCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "DMCore", targets: ["DMCore"])],
    targets: [
        .target(name: "DMCore", path: "Sources/DMCore"),
        .testTarget(
            name: "DMCoreTests",
            dependencies: ["DMCore"],
            path: "Tests/DMCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
