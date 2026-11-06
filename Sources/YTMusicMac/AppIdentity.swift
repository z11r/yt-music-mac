import Foundation
import WebKit

enum AppIdentity {
    static var preferences: UserDefaults {
        if Bundle.main.bundleIdentifier == identifier { return .standard }
        return UserDefaults(suiteName: identifier)!
    }
    static var resourceBundle: Bundle {
        if let url = Bundle.main.url(forResource: "YTMusicMac_YTMusicMac", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }
    static let displayName = "YT Music for Mac"
    static let releaseIdentifier = "io.github.z11r.ytmusicmac"
    static let debugIdentifier = "io.github.z11r.ytmusicmac.debug"

    static var identifier: String {
        #if DEBUG
        debugIdentifier
        #else
        releaseIdentifier
        #endif
    }

    static var websiteDataIdentifier: UUID {
        #if DEBUG
        UUID(uuid: (0x5D, 0x12, 0xB9, 0xC4, 0xC1, 0x39, 0x4D, 0x87,
                    0xA8, 0x6A, 0x61, 0x37, 0xBF, 0xCD, 0x1D, 0x01))
        #else
        UUID(uuid: (0x5D, 0x12, 0xB9, 0xC4, 0xC1, 0x39, 0x4D, 0x87,
                    0xA8, 0x6A, 0x61, 0x37, 0xBF, 0xCD, 0x1D, 0x02))
        #endif
    }

    static func applicationSupportDirectory(fileManager: FileManager = .default) throws -> URL {
        let parent = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = parent.appendingPathComponent(identifier, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
