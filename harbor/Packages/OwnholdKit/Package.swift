// swift-tools-version: 6.0
import PackageDescription

// OwnholdKit holds everything that isn't UI: the File Station, WebDAV and
// SMB clients, certificate pinning, connection selection, caching and
// offline storage. Keeping it UI-free means it can be unit-tested without a
// simulator.
let package = Package(
    name: "OwnholdKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OwnholdKit", targets: ["OwnholdKit"]),
    ],
    dependencies: [
        // SMB2/3 client in Swift. MIT licence. Pinned to an exact release.
        .package(url: "https://github.com/kishikawakatsumi/SMBClient", exact: "0.3.1"),
    ],
    targets: [
        .target(name: "OwnholdKit", dependencies: [.product(name: "SMBClient", package: "SMBClient")]),
        .testTarget(name: "OwnholdKitTests", dependencies: ["OwnholdKit"]),
    ]
)
