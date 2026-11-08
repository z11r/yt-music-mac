import Foundation
import Testing
@testable import MusicCore

struct ListeningLedgerTests {
    private let song = Track(id: "abcDEF12_-3", title: "Fixture Song", artist: "Fixture Artist", contentKind: .song)
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func eligibilityCountsHeardTimeOnceAtHalfTheTrack() throws {
        var ledger = ListeningLedger()
        let occurrence = occurrence()
        ledger.begin(track: song, occurrence: occurrence, intent: .newListen)
        for time in 1...60 { #expect(sample(&ledger, occurrence, position: Double(time), time: Double(time)) == nil) }
        let listen = try #require(sample(&ledger, occurrence, position: 61, time: 61))
        #expect(listen.listenedAt == 1_700_000_001)
        #expect(listen.metadata.title == song.title)
        ledger.markQueued(listen)
        for time in 62...120 { #expect(sample(&ledger, occurrence, position: Double(time), time: Double(time)) == nil) }
        #expect(ledger.state.receipts.count == 1)
    }

    @Test func fourMinutesWinsForLongTracks() throws {
        var ledger = ListeningLedger()
        let occurrence = occurrence()
        ledger.begin(track: song, occurrence: occurrence, intent: .newListen)
        for time in 1...240 { #expect(sample(&ledger, occurrence, position: Double(time), time: Double(time), duration: 1_800) == nil) }
        #expect(sample(&ledger, occurrence, position: 241, time: 241, duration: 1_800) != nil)
    }

    @Test func seeksGapsAndInterruptedIntervalsDoNotCountAsListening() {
        var ledger = ListeningLedger()
        let occurrence = occurrence()
        ledger.begin(track: song, occurrence: occurrence, intent: .newListen)
        _ = sample(&ledger, occurrence, position: 1, time: 1)
        _ = sample(&ledger, occurrence, position: 2, time: 2)
        _ = sample(&ledger, occurrence, position: 110, time: 3)
        #expect(ledger.state.current?.heardSeconds == 1)
        ledger.interrupt()
        _ = sample(&ledger, occurrence, position: 112, time: 100)
        _ = sample(&ledger, occurrence, position: 113, time: 101)
        #expect(ledger.state.current?.heardSeconds == 2)
        _ = sample(&ledger, occurrence, position: 114, time: 150)
        #expect(ledger.state.current?.heardSeconds == 2)
        _ = sample(&ledger, occurrence, position: 20, time: 151)
        _ = sample(&ledger, occurrence, position: 21, time: 152)
        #expect(ledger.state.current?.heardSeconds == 3)
    }

    @Test func outOfOrderAndDuplicateSamplesCannotCountAnIntervalTwice() {
        var ledger = ListeningLedger()
        let occurrence = occurrence()
        ledger.begin(track: song, occurrence: occurrence, intent: .newListen)
        _ = sample(&ledger, occurrence, position: 1, time: 1)
        _ = sample(&ledger, occurrence, position: 3, time: 3)
        _ = sample(&ledger, occurrence, position: 2, time: 2)
        _ = sample(&ledger, occurrence, position: 3, time: 3)
        _ = sample(&ledger, occurrence, position: 4, time: 4)
        #expect(ledger.state.current?.heardSeconds == 3)
    }

    @Test func retryAndRestorationRetainTheOriginalLogicalListen() throws {
        var ledger = ListeningLedger()
        let original = occurrence()
        ledger.begin(track: song, occurrence: original, intent: .newListen)
        var listen: EarnedListen?
        for time in 1...61 { listen = sample(&ledger, original, position: Double(time), time: Double(time)) ?? listen }
        let earned = try #require(listen)
        ledger.markQueued(earned)
        let state = try JSONDecoder().decode(ListeningLedgerState.self, from: JSONEncoder().encode(ledger.state))
        var restored = ListeningLedger(state: state)
        let retry = occurrence(entryID: original.entryID, generation: 2)
        restored.begin(track: song, occurrence: retry, intent: .continuation)
        for time in 70...120 { #expect(sample(&restored, retry, position: Double(time), time: Double(time)) == nil) }
        #expect(restored.state.current?.id == earned.id)
        #expect(restored.state.current?.queued == true)
    }

    @Test func naturalRepeatAndExplicitNewPlayEarnIndependentListens() throws {
        var ledger = ListeningLedger()
        let original = occurrence()
        ledger.begin(track: song, occurrence: original, intent: .newListen)
        var first: EarnedListen?
        for time in 1...61 { first = sample(&ledger, original, position: Double(time), time: Double(time)) ?? first }
        let earned = try #require(first); ledger.markQueued(earned)
        _ = sample(&ledger, original, position: 120, time: 120, ended: true)
        let next = occurrence(entryID: original.entryID, generation: 2)
        ledger.begin(track: song, occurrence: next, intent: .newListen)
        var repeated: EarnedListen?
        for time in 1...61 { repeated = sample(&ledger, next, position: Double(time), time: Double(time + 120)) ?? repeated }
        #expect(try #require(repeated).id != earned.id)
        #expect(repeated?.entryID == earned.entryID)
    }

    @Test func unknownRecoveredPlaysCannotInventASecondHistoricalListen() {
        var ledger = ListeningLedger()
        let occurrence = occurrence()
        ledger.begin(track: song, occurrence: occurrence, intent: .continuation)
        for time in 1...120 { #expect(sample(&ledger, occurrence, position: Double(time), time: Double(time)) == nil) }
        #expect(ledger.state.current?.suppressed == true)
    }

    @Test func changingConsentCannotResumeAnOldPartialListen() {
        var ledger = ListeningLedger()
        let occurrence = occurrence()
        ledger.begin(track: song, occurrence: occurrence, intent: .newListen)
        for time in 1...40 { _ = sample(&ledger, occurrence, position: Double(time), time: Double(time)) }
        ledger.suspendCurrent()
        ledger.begin(track: song, occurrence: occurrence, intent: .continuation)
        for time in 41...120 { #expect(sample(&ledger, occurrence, position: Double(time), time: Double(time)) == nil) }
        #expect(ledger.state.current?.suppressed == true)
        ledger.begin(track: song, occurrence: occurrence, intent: .newListen)
        var listen: EarnedListen?
        for time in 1...61 { listen = sample(&ledger, occurrence, position: Double(time), time: Double(time + 120)) ?? listen }
        #expect(listen != nil)
    }

    @Test func uploadsPodcastsUnknownMetadataAndShortContentStayExcluded() {
        let excluded = [Track(id: song.id, title: song.title, artist: song.artist, origin: .upload, contentKind: .song),
            Track(id: song.id, title: song.title, artist: song.artist, contentKind: .podcastEpisode),
            Track(id: song.id, title: song.title, artist: song.artist),
            Track(id: song.id, title: song.title, artist: "Unknown artist", contentKind: .song),
            Track(id: song.id, title: song.title, artist: "Artiste inconnu", contentKind: .song)]
        let occurrence = occurrence()
        for track in excluded {
            var ledger = ListeningLedger()
            ledger.begin(track: track, occurrence: occurrence, intent: .newListen)
            #expect(ledger.state.current == nil)
        }
        var ledger = ListeningLedger()
        ledger.begin(track: song, occurrence: occurrence, intent: .newListen)
        for time in 1...30 { #expect(sample(&ledger, occurrence, position: Double(time), time: Double(time), duration: 30) == nil) }
        #expect(ledger.state.current?.heardSeconds == 0)
    }

    private func occurrence(entryID: UUID = UUID(), generation: UInt64 = 1) -> PlaybackOccurrence {
        .init(sessionID: UUID(), entryID: entryID, trackID: song.id, generation: generation)
    }
    private func sample(_ ledger: inout ListeningLedger, _ occurrence: PlaybackOccurrence, position: Double, time: Double,
                        duration: Double = 120, ended: Bool = false) -> EarnedListen? {
        ledger.sample(occurrence: occurrence, position: position, duration: duration, monotonicTime: time,
                      wallTime: start.addingTimeInterval(time), ended: ended)
    }
}
