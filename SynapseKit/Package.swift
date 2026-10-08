// swift-tools-version: 5.9
import PackageDescription

// SynapseKit: everything in Synapse that isn't UI. Foundation only, so it builds and tests on Linux too.
let package = Package(
    name: "SynapseKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SynapseKit", targets: ["SynapseKit"]),
    ],
    targets: [
        .target(name: "SynapseKit"),
        .testTarget(name: "SynapseKitTests", dependencies: ["SynapseKit"]),
    ]
)
