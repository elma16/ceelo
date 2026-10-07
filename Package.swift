// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ceelo",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "ceelo",
            targets: ["ceelo"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", .upToNextMinor(from: "0.10.0"))
    ],
    targets: [
        .target(
            name: "CeeloCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/CeeloCore"
        ),
        .executableTarget(
            name: "ceelo",
            dependencies: [
                "CeeloCore"
            ],
            path: "Sources/ceelo"
        ),
        .executableTarget(
            name: "ceelo-bench",
            dependencies: [
                "CeeloCore",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources/ceelo-bench"
        ),
        .testTarget(
            name: "CeeloCoreTests",
            dependencies: [
                "CeeloCore",
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Tests/CeeloCoreTests"
        )
    ]
)
