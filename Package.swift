// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Roomy",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Roomy", targets: ["Roomy"]),
        .executable(name: "roomy-cli", targets: ["roomy-cli"]),
        .library(name: "RoomyCore", targets: ["RoomyCore"]),
    ],
    targets: [
        .target(name: "RoomyCore"),
        .executableTarget(name: "Roomy", dependencies: ["RoomyCore"]),
        .executableTarget(name: "roomy-cli", dependencies: ["RoomyCore"]),
        .testTarget(name: "RoomyCoreTests", dependencies: ["RoomyCore"]),
    ]
)
