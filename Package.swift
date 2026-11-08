// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "YTMusicMac",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "YTMusicMac", targets: ["YTMusicMac"]),
        .library(name: "MusicCore", targets: ["MusicCore"]),
    ],
    targets: [
        .target(name: "MusicCore", resources: [.process("Resources")]),
        .target(name: "YouTubeMusic", dependencies: ["MusicCore"], resources: [.process("Resources")]),
        .executableTarget(
            name: "YTMusicMac",
            dependencies: ["MusicCore", "YouTubeMusic"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "MusicCoreTests", dependencies: ["MusicCore"]),
        .testTarget(
            name: "YouTubeMusicTests",
            dependencies: ["YouTubeMusic", "MusicCore"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(name: "YTMusicMacTests", dependencies: ["YTMusicMac", "MusicCore"]),
    ],
    swiftLanguageModes: [.v6]
)
