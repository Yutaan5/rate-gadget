// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "RateGadget",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "RateGadgetCore",
            path: "Sources/RateGadget",
            swiftSettings: [.unsafeFlags(["-enable-testing"])]
        ),
        .executableTarget(
            name: "RateGadget",
            dependencies: ["RateGadgetCore"],
            path: "Sources/RateGadgetApp"
        ),
        .executableTarget(
            name: "RateGadgetTests",
            dependencies: ["RateGadgetCore"],
            path: "Tests/RateGadgetTests"
        )
    ]
)
