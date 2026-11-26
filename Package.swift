// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Koffer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KofferCore", targets: ["KofferCore"]),
        .executable(name: "Koffer", targets: ["Koffer"]),
    ],
    targets: [
        .target(name: "KofferCore", path: "Sources/KofferCore"),
        .executableTarget(name: "Koffer", dependencies: ["KofferCore"], path: "Sources/Koffer"),
        .testTarget(
            name: "KofferCoreTests",
            dependencies: ["KofferCore"],
            path: "Tests/KofferCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
