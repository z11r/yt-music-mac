import Foundation
import Testing
@testable import MusicCore

@Suite("Local song-rule predicates")
struct LocalSongRuleTests {
    private let known = LocalSongRuleSong(videoID: "abcDEF12_-3", title: "Café Lights", artist: "The Artist", album: "Evening", duration: 180, isExplicit: false)
    private let unknown = LocalSongRuleSong(videoID: "xyzABC34_-5")

    @Test func unknownExplicitStatusIsIndependentOfKnownFalse() {
        let clean = LocalSongRuleClause(field: .explicit, operation: .isFalse)
        let explicit = LocalSongRuleClause(field: .explicit, operation: .isTrue)
        let missing = LocalSongRuleClause(field: .explicit, operation: .isUnknown)
        #expect(clean.evaluate(known) == .matches && explicit.evaluate(known) == .doesNotMatch)
        #expect(clean.evaluate(unknown) == .unknown && explicit.evaluate(unknown) == .unknown)
        #expect(missing.evaluate(unknown) == .matches && missing.evaluate(known) == .doesNotMatch)
    }

    @Test func textRulesUseCaseAndAccentInsensitiveMatchingAndKeepUnknownNegationsUnknown() {
        #expect(LocalSongRuleClause(text: "CAFE").evaluate(known) == .matches)
        #expect(LocalSongRuleClause(field: .artist, operation: .equals, text: "the artist").evaluate(known) == .matches)
        #expect(LocalSongRuleClause(field: .album, operation: .doesNotContain, text: "Morning").evaluate(known) == .matches)
        #expect(LocalSongRuleClause(field: .album, operation: .doesNotEqual, text: "Evening").evaluate(known) == .doesNotMatch)
        #expect(LocalSongRuleClause(field: .album, operation: .doesNotContain, text: "Morning").evaluate(unknown) == .unknown)
        #expect(LocalSongRuleClause(field: .artist, operation: .isKnown).evaluate(unknown) == .doesNotMatch)
    }

    @Test func durationComparisonsRespectBoundariesAndNeverTurnMissingDurationIntoZero() {
        #expect(LocalSongRuleClause(field: .duration, operation: .lessThan, number: 180).evaluate(known) == .doesNotMatch)
        #expect(LocalSongRuleClause(field: .duration, operation: .atMost, number: 180).evaluate(known) == .matches)
        #expect(LocalSongRuleClause(field: .duration, operation: .atLeast, number: 180).evaluate(known) == .matches)
        #expect(LocalSongRuleClause(field: .duration, operation: .greaterThan, number: 180).evaluate(known) == .doesNotMatch)
        #expect(LocalSongRuleClause(field: .duration, operation: .lessThan, number: 1).evaluate(unknown) == .unknown)
        let zero = LocalSongRuleSong(videoID: "abcDEF12_-3", duration: 0)
        #expect(LocalSongRuleClause(field: .duration, operation: .atMost, number: 0).evaluate(zero) == .matches)
    }

    @Test func allAndAnyUseThreeValuedLogic() {
        let trueClause = LocalSongRuleClause(text: "Lights")
        let falseClause = LocalSongRuleClause(text: "Absent")
        let unknownClause = LocalSongRuleClause(field: .album, operation: .contains, text: "Album")
        let song = LocalSongRuleSong(videoID: "abcDEF12_-3", title: "Lights")
        #expect(LocalSongRule(name: "All", clauses: [trueClause, unknownClause]).evaluate(song) == .unknown)
        #expect(LocalSongRule(name: "All", clauses: [falseClause, unknownClause]).evaluate(song) == .doesNotMatch)
        #expect(LocalSongRule(name: "Any", match: .any, clauses: [trueClause, unknownClause]).evaluate(song) == .matches)
        #expect(LocalSongRule(name: "Any", match: .any, clauses: [falseClause, unknownClause]).evaluate(song) == .unknown)
        #expect(LocalSongRule(name: "Any", match: .any, clauses: [falseClause]).evaluate(song) == .doesNotMatch)
    }

    @Test func metadataCaptureKeepsMissingValuesAndUploadOriginWithoutSavingArtworkOrLinks() throws {
        let track = Track(id: "abcDEF12_-3", title: "Title", artist: "Unknown artist", album: nil,
            artworkURL: URL(string: "https://example.com/private?token=secret"), duration: nil,
            albumReference: TrackMetadataReference(id: "OpaqueAlbum", title: "Not an established album field"), isExplicit: nil, origin: .upload)
        let song = LocalSongRuleSong(track: track)
        #expect(song.artist == nil && song.album == nil && song.duration == nil && song.isExplicit == nil)
        #expect(song.origin == .upload && song.track.origin == .upload)
        let text = String(decoding: try JSONEncoder().encode(song), as: UTF8.self)
        for absent in ["artwork", "https", "token", "OpaqueAlbum", "Not an established"] { #expect(!text.contains(absent)) }
        let invalid = LocalSongRuleSong(track: Track(id: "abcDEF12_-3", title: "Bad\u{0000}title", artist: String(repeating: "x", count: 4_097)))
        #expect(invalid.title == nil && invalid.artist == nil)
    }

    @Test func evaluationKeepsEveryMatchingOccurrenceInSourceOrderAndCountsUndecidableResults() {
        let first = LocalSongRuleSong(videoID: "abcDEF12_-3", title: "Match", album: "Album")
        let repeated = LocalSongRuleSong(videoID: "abcDEF12_-3", title: "Match", album: "Album")
        let missing = LocalSongRuleSong(videoID: "xyzABC34_-5", title: "Other")
        let snapshot = LocalSongRuleSnapshot(capturedAt: Date(), sourceName: "Loaded playlist", songs: [first, missing, repeated])
        let rule = LocalSongRule(name: "Albums", clauses: [LocalSongRuleClause(field: .album, text: "Album")])
        let result = LocalSongRuleEvaluation(rule: rule, snapshot: snapshot)
        #expect(result.matches == [first, repeated] && result.unknownCount == 1)
        #expect(result.matches[0].id != result.matches[1].id)
        var queue = PlaybackQueue()
        queue.append(result.matches.map(\.track))
        #expect(queue.entries.map(\.track.id) == ["abcDEF12_-3", "abcDEF12_-3"])
        #expect(Set(queue.entries.map(\.id)).count == 2)
    }
}
