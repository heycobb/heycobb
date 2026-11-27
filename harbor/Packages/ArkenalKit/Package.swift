// swift-tools-version: 6.0
import PackageDescription

// ArkenalKit holds everything that isn't UI: the File Station, WebDAV and
// SMB clients, certificate pinning, connection selection, caching and
// offline storage. Keeping it UI-free means it can be unit-tested without a
// simulator.
let package = Package(
    name: "ArkenalKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ArkenalKit", targets: ["ArkenalKit"]),
    ],
    dependencies: [
        // SMB2/3 client in Swift. MIT licence. Pinned to an exact release.
        .package(url: "https://github.com/kishikawakatsumi/SMBClient", exact: "0.3.1"),
    ],
    targets: [
        .target(name: "ArkenalKit", dependencies: [.product(name: "SMBClient", package: "SMBClient")]),
        .testTarget(name: "ArkenalKitTests", dependencies: ["ArkenalKit"]),
    ]
)
