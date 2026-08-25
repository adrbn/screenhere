// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenHere",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ScreenHere",
            path: "Sources/ScreenHere"
        ),
        .testTarget(
            name: "ScreenHereTests",
            dependencies: ["ScreenHere"],
            path: "Tests/ScreenHereTests"
        ),
    ]
)
