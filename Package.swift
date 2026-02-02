// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "parakeet_ptt",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.0.1")
    ],
    targets: [
        .executableTarget(
            name: "parakeet_ptt",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        )
    ]
)
