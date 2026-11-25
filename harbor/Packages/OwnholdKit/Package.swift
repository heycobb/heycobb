// swift-tools-version: 6.0
import PackageDescription

// OwnholdKit holds everything that isn't UI: the File Station API client,
// certificate pinning, connection selection, caching and offline storage.
// Keeping it UI-free means it can be unit-tested without a simulator.
let package = Package(
    name: "OwnholdKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OwnholdKit", targets: ["OwnholdKit"]),
    ],
    targets: [
        .target(name: "OwnholdKit"),
        .testTarget(name: "OwnholdKitTests", dependencies: ["OwnholdKit"]),
    ]
)
