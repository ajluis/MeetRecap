// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetRecap",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MeetRecap", targets: ["MeetRecap"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.13.4")
    ],
    targets: [
        .executableTarget(
            name: "MeetRecap",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "MeetRecap",
            resources: [
                .process("Preview Content")
            ]
        )
    ]
)
