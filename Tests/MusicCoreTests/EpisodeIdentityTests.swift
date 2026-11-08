import Foundation
import Testing
@testable import MusicCore

struct EpisodeIdentityTests {
    @Test func episodeMetadataIsOptionalAndSurvivesQueueRestoration() throws {
        let legacy = try JSONDecoder().decode(Track.self, from: Data(#"{"id":"abcDEF12_-3","title":"Song","artist":"Artist"}"#.utf8))
        #expect(legacy.contentKind == nil && legacy.episode == nil)
        let metadata = EpisodeMetadata(identity: .init(browseID: "MPEDcanonical", showBrowseID: "MPSPPLshow"), serviceProgressFraction: 0.5)
        var queue = PlaybackQueue()
        queue.replace(with: [Track(id: "abcDEF12_-3", title: "Episode", artist: "Show", contentKind: .podcastEpisode, episode: metadata)])
        let data = try JSONEncoder().encode(queue.snapshot())
        let restored = try PlaybackQueue(snapshot: JSONDecoder().decode(QueueSnapshot.self, from: data))
        #expect(restored.currentTrack?.episode == metadata)
        #expect(restored.currentOccurrence == nil)
    }

    @Test func metadataUpdatesCannotReplaceAnotherEpisodeSharingAVideoID() {
        let first = EpisodeMetadata(identity: .init(browseID: "MPEDone"))
        let second = EpisodeMetadata(identity: .init(browseID: "MPEDtwo"))
        var queue = PlaybackQueue()
        queue.replace(with: [Track(id: "abcDEF12_-3", title: "One", artist: "Show", contentKind: .podcastEpisode, episode: first),
            Track(id: "abcDEF12_-3", title: "Two", artist: "Show", contentKind: .podcastEpisode, episode: second)])
        queue.updateTrack(Track(id: "abcDEF12_-3", title: "Updated one", artist: "Show", contentKind: .podcastEpisode, episode: first))
        #expect(queue.entries[0].track.title == "Updated one")
        #expect(queue.entries[1].track.title == "Two")
        #expect(first.identity.key != second.identity.key)
        #expect(EpisodeIdentity(browseID: "MPEDone", showBrowseID: "MPSPPLknown").key == first.identity.key)
    }
}
