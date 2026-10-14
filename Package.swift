// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CalSync",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "CalSync",
            path: "Sources/CalSync",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
