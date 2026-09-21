// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WorkTempoMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WorkTempoCore", targets: ["WorkTempoCore"]),
        .executable(name: "WorkTempo", targets: ["WorkTempoMenuBar"]),
    ],
    targets: [
        .target(name: "WorkTempoCore"),
        .executableTarget(
            name: "WorkTempoMenuBar",
            dependencies: ["WorkTempoCore"]
        ),
        .testTarget(name: "WorkTempoCoreTests", dependencies: ["WorkTempoCore"]),
    ]
)
