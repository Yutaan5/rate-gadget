// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "RateGadget",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "RateGadget",
            path: "Sources/RateGadget"
        )
    ]
)
