// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenHere",
    platforms: [.macOS(.v13)],
    dependencies: [
        // The only dependency, and it earns it: Sparkle is what lets a signed
        // release update itself instead of asking the user to re-download.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "ScreenHere",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/ScreenHere",
            linkerSettings: [
                // SwiftPM does not assemble app bundles, so the framework is
                // copied into Contents/Frameworks by scripts/build-dmg.sh and
                // found at runtime through this rpath.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "ScreenHereTests",
            dependencies: ["ScreenHere"],
            path: "Tests/ScreenHereTests",
            linkerSettings: [
                // The tests link the app target, which links Sparkle, but the
                // xctest bundle gets no rpath to the build products directory
                // where SwiftPM leaves the framework. From
                // Products/<config>/ScreenHereTests.xctest/Contents/MacOS/,
                // that directory is three levels up.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])
            ]
        ),
    ]
)
