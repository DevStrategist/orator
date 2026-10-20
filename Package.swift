// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Orator",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Orator", targets: ["Orator"]),
        .executable(name: "OratorCapture", targets: ["OratorCapture"])
    ],
    targets: [
        .target(name: "OratorCore"),
        .executableTarget(name: "Orator", dependencies: ["OratorCore"]),
        .executableTarget(name: "OratorCapture", dependencies: ["OratorCore"]),
        .testTarget(name: "OratorCoreTests", dependencies: ["OratorCore"]),
        .testTarget(name: "OratorTests", dependencies: ["Orator", "OratorCore"])
    ]
)
