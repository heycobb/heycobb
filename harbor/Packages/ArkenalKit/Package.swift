// swift-tools-version: 6.0
import PackageDescription

// ArkenalKit holds everything that isn't UI: the File Station, WebDAV and
// SMB clients, certificate pinning, connection selection, caching and
// offline storage. Keeping it UI-free means it can be unit-tested without a
// simulator.
let package = Package(
    name: "ArkenalKit",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "ArkenalKit", targets: ["ArkenalKit"]),
    ],
    dependencies: [
        // SMB2/3 client in Swift. MIT licence. Pinned to an exact release.
        // main after 0.3.1: fixes large SMB downloads stalling (no tagged release yet).
        .package(url: "https://github.com/kishikawakatsumi/SMBClient", revision: "66eafaa6d17e034e8036dee4b3ebc1b52cb53919"),
    ],
    targets: [
        .target(name: "ArkenalKit", dependencies: [.product(name: "SMBClient", package: "SMBClient")]),
        .testTarget(name: "ArkenalKitTests", dependencies: ["ArkenalKit"]),
    ]
)
