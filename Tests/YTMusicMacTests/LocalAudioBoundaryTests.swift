import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

@Suite("Local audio boundary regressions")
struct LocalAudioBoundaryTests {
    @Test func bothBookmarkModesExplicitlySuppressImplicitAcquisition() {
        let ordinary = NativeLocalAudioBookmarkAccess(mode: .ordinary).resolutionOptions
        let scoped = NativeLocalAudioBookmarkAccess(mode: .securityScopedReadOnly).resolutionOptions
        #expect(ordinary == [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing])
        #expect(scoped == [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing, .withSecurityScope])
    }

    @Test func rawEncodedNulIsRejectedButARealPercentFilenameIsAllowed() throws {
        let encoded = try #require(URL(string: "file:///fixture/name%00suffix.wav"))
        #expect(throws: LocalAudioAccessError.invalidURL) { try LocalAudioFilePolicy.validateURL(encoded) }
        let literal = URL(fileURLWithPath: "/fixture/literal%00name.wav")
        #expect(literal.absoluteString.contains("%2500"))
        try LocalAudioFilePolicy.validateURL(literal)
    }

    @Test func localMarkersCannotPublishAServiceIDButKeepTransportState() throws {
        let reference = LocalAudioReference(libraryID: UUID(), fileID: UUID())
        let tracks = [Track(id: "abcdefghijk", title: "Private", artist: "Artist", origin: .localFile),
            Track(id: "abcdefghijk", title: "Private", artist: "Artist", localAudioReference: reference),
            Track(id: "LoCaL:orphan", title: "Private", artist: "Artist")]
        for track in tracks {
            let value = ScriptingPlayerInfo(playing: true, buffering: true, signedIn: false, currentTrack: track,
                position: 12, duration: 120, volume: 0.4, queueCount: 2, hasError: false)
            #expect(value.currentTrackID == nil)
            let json = try #require(try JSONSerialization.jsonObject(with: Data(value.json().utf8)) as? [String: Any])
            #expect(json["currentTrackID"] == nil)
            #expect(json["playing"] as? Bool == true)
            #expect(json["buffering"] as? Bool == true)
            #expect(json["signedIn"] as? Bool == false)
            #expect(json["position"] as? Double == 12 && json["duration"] as? Double == 120)
            #expect(json["volume"] as? Double == 0.4 && json["queueCount"] as? Int == 2)
        }
    }

    @Test func serviceStatusKeepsCatalogUploadsAndLegacyNonElevenCharacterFixtures() {
        for track in [Track(id: "abcdefghijk", title: "Catalog", artist: "Artist"),
                      Track(id: "uploadvideo", title: "Uploaded", artist: "Artist", origin: .upload),
                      Track(id: "scene-fixture", title: "Fixture", artist: "Artist")] {
            let value = ScriptingPlayerInfo(playing: false, buffering: false, signedIn: true, currentTrack: track,
                position: 0, duration: 120, volume: 0.5, queueCount: 1, hasError: false)
            #expect(value.currentTrackID == track.id)
        }
        let raw = ScriptingPlayerInfo(playing: false, buffering: false, signedIn: false, currentTrackID: "LOCAL:orphan",
            position: 0, duration: 0, volume: 0.5, queueCount: 1, hasError: false)
        #expect(raw.currentTrackID == nil)
    }
}
