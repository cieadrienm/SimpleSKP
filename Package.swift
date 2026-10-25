// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimpleSKP",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SimpleSKPCore", targets: ["SimpleSKPCore"]),
        .library(name: "SimpleSKPViewport", targets: ["SimpleSKPViewport"]),
        .executable(name: "SimpleSKP", targets: ["SimpleSKP"]),
    ],
    targets: [
        .target(name: "SimpleSKPCore"),
        .target(name: "SimpleSKPViewport", dependencies: ["SimpleSKPCore"]),
        .executableTarget(name: "SimpleSKP", dependencies: ["SimpleSKPCore", "SimpleSKPViewport"]),
        .testTarget(name: "SimpleSKPCoreTests", dependencies: ["SimpleSKPCore"]),
        .testTarget(name: "SimpleSKPViewportTests", dependencies: ["SimpleSKPViewport", "SimpleSKPCore"]),
        .testTarget(name: "SimpleSKPAppTests", dependencies: ["SimpleSKP", "SimpleSKPCore", "SimpleSKPViewport"]),
    ],
    swiftLanguageModes: [.v5]
)
