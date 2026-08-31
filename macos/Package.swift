// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SourceTempoMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SourceTempoCore", targets: ["SourceTempoCore"]),
    ],
    targets: [
        .target(name: "SourceTempoCore"),
        .testTarget(name: "SourceTempoCoreTests", dependencies: ["SourceTempoCore"]),
    ]
)
