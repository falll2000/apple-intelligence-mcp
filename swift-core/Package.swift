// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppleIntelCore",
    platforms: [
        .macOS("26.0")  // Use string syntax because older PackageDescription versions do not know .v26.
    ],
    targets: [
        .executableTarget(
            name: "AppleIntelCore",
            path: "Sources/AppleIntelCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
