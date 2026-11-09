// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimpleSKP",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SimpleSKPFBX", targets: ["SimpleSKPFBX"]),
        .library(name: "SimpleSKPCore", targets: ["SimpleSKPCore"]),
        .library(name: "SimpleSKPVideoBridge", targets: ["SimpleSKPVideoBridge"]),
        .library(name: "SimpleSKPViewport", targets: ["SimpleSKPViewport"]),
        .library(name: "SimpleSKPMCPCore", targets: ["SimpleSKPMCPCore"]),
        .executable(name: "SimpleSKP", targets: ["SimpleSKP"]),
        .executable(name: "simpleskp-mcp", targets: ["simpleskp-mcp"]),
    ],
    targets: [
        .target(
            name: "SimpleSKPFBX",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-O3", "-Wno-unused-function"]),
            ]
        ),
        .target(
            name: "SimpleSKPCore",
            dependencies: ["SimpleSKPFBX"],
            linkerSettings: [
                .linkedLibrary("z"),
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "/Applications/SketchUp.app/Contents/Frameworks",
                ]),
            ]
        ),
        .target(
            name: "SimpleSKPVideoBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("IOSurface"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        .target(name: "SimpleSKPViewport", dependencies: ["SimpleSKPCore", "SimpleSKPVideoBridge"]),
        .executableTarget(name: "SimpleSKP", dependencies: ["SimpleSKPCore", "SimpleSKPViewport", "SimpleSKPVideoBridge"]),
        .target(name: "SimpleSKPMCPCore"),
        .executableTarget(name: "simpleskp-mcp", dependencies: ["SimpleSKPMCPCore"]),
        .testTarget(name: "SimpleSKPCoreTests", dependencies: ["SimpleSKPCore"]),
        .testTarget(name: "SimpleSKPViewportTests", dependencies: ["SimpleSKPViewport", "SimpleSKPCore", "SimpleSKPVideoBridge"]),
        .testTarget(name: "SimpleSKPAppTests", dependencies: ["SimpleSKP", "SimpleSKPCore", "SimpleSKPViewport", "SimpleSKPVideoBridge", "SimpleSKPMCPCore"]),
    ],
    swiftLanguageModes: [.v5]
)
