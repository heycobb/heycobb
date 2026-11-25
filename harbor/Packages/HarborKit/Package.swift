// swift-tools-version: 6.0
import PackageDescription

// HarborKit holds everything that isn't UI: the File Station API client,
// certificate pinning, connection selection, caching and offline storage.
// Keeping it UI-free means it can be unit-tested without a simulator.
let package = Package(
    name: "HarborKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HarborKit", targets: ["HarborKit"]),
    ],
    targets: [
        .target(name: "HarborKit"),
        .testTarget(name: "HarborKitTests", dependencies: ["HarborKit"]),
    ]
)
