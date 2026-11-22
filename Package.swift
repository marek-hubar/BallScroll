// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BallScroll",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure scroll logic: no AppKit, no event taps, fully unit-testable.
        .target(
            name: "BallScrollCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The menu bar app: event tap, pointer freeze, scroll posting, settings UI.
        .executableTarget(
            name: "BallScroll",
            dependencies: ["BallScrollCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BallScrollCoreTests",
            dependencies: ["BallScrollCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
