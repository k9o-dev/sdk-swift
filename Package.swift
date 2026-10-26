// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "K9OSwift",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "K9OGate", targets: ["K9OGate"]),
        .library(name: "K9OCore", targets: ["K9OCore"]),
    ],
    targets: [
        .target(name: "K9OGate", dependencies: [], path: "Sources/K9OGate"),
        .target(name: "K9OCore", dependencies: [], path: "Sources/K9OCore"),
        .testTarget(name: "K9OGateTests", dependencies: ["K9OGate"], path: "Tests/K9OGateTests"),
        .testTarget(name: "K9OCoreTests", dependencies: ["K9OCore"], path: "Tests/K9OCoreTests"),
    ]
)
