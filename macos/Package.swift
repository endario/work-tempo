// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SourceTempoMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SourceTempoCore", targets: ["SourceTempoCore"]),
        .executable(name: "SourceTempo", targets: ["SourceTempoMenuBar"]),
    ],
    targets: [
        .target(name: "SourceTempoCore"),
        .executableTarget(
            name: "SourceTempoMenuBar",
            dependencies: ["SourceTempoCore"]
        ),
        .testTarget(name: "SourceTempoCoreTests", dependencies: ["SourceTempoCore"]),
    ]
)
