// swift-tools-version: 6.2
import PackageDescription

// Both the provider and its SwiftUI cross-import overlay must remain optional
// when the universal app or its tests run on the macOS 14 baseline.
let optionalTranslationFrameworks: [LinkerSetting] = [.unsafeFlags([
    "-Xlinker", "-weak_framework", "-Xlinker", "Translation",
    "-Xlinker", "-weak_framework", "-Xlinker", "_Translation_SwiftUI",
], .when(platforms: [.macOS]))]

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
            resources: [.process("Resources")],
            linkerSettings: optionalTranslationFrameworks
        ),
        .testTarget(name: "MusicCoreTests", dependencies: ["MusicCore"]),
        .testTarget(
            name: "YouTubeMusicTests",
            dependencies: ["YouTubeMusic", "MusicCore"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(name: "YTMusicMacTests", dependencies: ["YTMusicMac", "MusicCore"], linkerSettings: optionalTranslationFrameworks),
    ],
    swiftLanguageModes: [.v6]
)
