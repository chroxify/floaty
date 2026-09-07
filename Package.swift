// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Floaty",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Floaty",
            path: "Sources/Floaty"
        ),
        .testTarget(name: "FloatyTests", dependencies: ["Floaty"])
    ]
)
