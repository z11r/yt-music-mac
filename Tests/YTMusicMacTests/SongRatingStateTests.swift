import Foundation
import Testing
import YouTubeMusic
@testable import YTMusicMac

@MainActor
@Suite("Song rating state")
struct SongRatingStateTests {
    @Test func legacyFalseDoesNotPretendToEstablishNeutral() {
        let legacy = MusicPage(title: "Legacy", sections: [], items: [], likeStates: ["liked": true, "unknown": false])
        #expect(legacy.ratings == ["liked": .liked])
        #expect(legacy.likeStates["unknown"] == false)
        let explicit = MusicPage(title: "Explicit", sections: [], items: [], likeStates: ["song": false], ratings: ["song": .disliked])
        #expect(explicit.ratings["song"] == .disliked)
    }

    @Test func encodedRatingsRoundTripWithoutLosingDislike() throws {
        let ratings: [String: MusicRating] = ["one": .liked, "two": .neutral, "three": .disliked]
        let restored = try JSONDecoder().decode([String: MusicRating].self, from: JSONEncoder().encode(ratings))
        #expect(restored == ratings)
    }

    @Test func confirmedWriteSurvivesAReadThatStartedEarlier() {
        let state = SongRatings()
        let oldRead = state.beginRead()
        state.confirm(.disliked, for: "song")
        state.observe(["song": .neutral, "other": .liked], from: oldRead)
        #expect(state.values["song"] == .disliked)
        #expect(state.values["other"] == .liked)
    }

    @Test func uncertainWriteBecomesUnknownAndRejectsOldSnapshots() {
        let state = SongRatings()
        state.confirm(.liked, for: "song")
        let oldRead = state.beginRead()
        state.invalidate("song")
        state.observe(["song": .liked], from: oldRead)
        #expect(state.values["song"] == nil)
        let fresh = state.beginRead()
        state.observe(["song": .disliked], from: fresh)
        #expect(state.values["song"] == .disliked)
    }

    @Test func accountResetRejectsEveryOldAccountRead() {
        let state = SongRatings()
        let oldRead = state.beginRead()
        state.confirm(.disliked, for: "song")
        state.clear()
        state.observe(["song": .liked], from: oldRead)
        #expect(state.values.isEmpty)
        let fresh = state.beginRead()
        state.observe(["song": .neutral], from: fresh)
        #expect(state.values["song"] == .neutral)
    }

    @Test func outOfOrderReadsDoNotReplaceANewerObservation() {
        let state = SongRatings()
        let oldRead = state.beginRead()
        let newRead = state.beginRead()
        state.observe(["song": .disliked], from: newRead)
        state.observe(["song": .neutral], from: oldRead)
        #expect(state.values["song"] == .disliked)
    }

    @Test func freshAuthoritativeReadCanObserveAnExternalRatingChange() {
        let state = SongRatings()
        state.confirm(.disliked, for: "song")
        let fresh = state.beginRead()
        state.observe(["song": .neutral], from: fresh)
        #expect(state.values["song"] == .neutral)
    }
}
