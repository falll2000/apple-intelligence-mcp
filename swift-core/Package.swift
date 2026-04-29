// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppleIntelCore",
    platforms: [
        .macOS("26.0")  // 用字串格式繞過舊版 PackageDescription 不認識 .v26 的問題
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
