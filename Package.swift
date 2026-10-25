// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimpleSKP",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SimpleSKPCore", targets: ["SimpleSKPCore"]),
        .library(name: "SimpleSKPViewport", targets: ["SimpleSKPViewport"]),
        .library(name: "SimpleSKPMCPCore", targets: ["SimpleSKPMCPCore"]),
        .executable(name: "SimpleSKP", targets: ["SimpleSKP"]),
        .executable(name: "simpleskp-mcp", targets: ["simpleskp-mcp"]),
    ],
    targets: [
        .target(name: "SimpleSKPCore"),
        .target(name: "SimpleSKPViewport", dependencies: ["SimpleSKPCore"]),
        .executableTarget(name: "SimpleSKP", dependencies: ["SimpleSKPCore", "SimpleSKPViewport"]),
        .target(name: "SimpleSKPMCPCore"),
        .executableTarget(name: "simpleskp-mcp", dependencies: ["SimpleSKPMCPCore"]),
        .testTarget(name: "SimpleSKPCoreTests", dependencies: ["SimpleSKPCore"]),
        .testTarget(name: "SimpleSKPViewportTests", dependencies: ["SimpleSKPViewport", "SimpleSKPCore"]),
        .testTarget(name: "SimpleSKPAppTests", dependencies: ["SimpleSKP", "SimpleSKPCore", "SimpleSKPViewport", "SimpleSKPMCPCore"]),
    ],
    swiftLanguageModes: [.v5]
)
