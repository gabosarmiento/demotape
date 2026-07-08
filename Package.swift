// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "DemoTape",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "DemoTape",
            path: "Sources/DemoTape"
        )
    ]
)
