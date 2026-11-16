// swift-tools-version: 5.10
import PackageDescription

// Library-only embedding; upstream CLI dependencies are intentionally omitted.
let package = Package(
    name: "RifeMetal",
    platforms: [.macOS(.v13)],
    products: [.library(name: "RifeMetal", targets: ["RifeMetal", "RifeMetalCore"])],
    targets: [
        .target(name: "RifeMetal", dependencies: ["RifeMetalCore"],
                resources: [.copy("Resources/rife-v4.25.rmw"), .copy("Resources/Notices")]),
        .target(name: "RifeMetalCore", exclude: ["Shaders"],
                plugins: [.plugin(name: "CompileMetalShaders")]),
        .plugin(name: "CompileMetalShaders", capability: .buildTool()),
    ]
)
