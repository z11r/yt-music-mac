import Foundation
import Testing
import YouTubeMusic
@testable import YTMusicMac

@Suite("Visible lyrics requests") @MainActor
struct LyricsSessionTests {
    @Test func openingNoSongDoesNotRequestAnything() {
        let lyrics = LyricsSession { _ in
            Issue.record("No song was selected")
            return .unavailable
        }
        #expect(lyrics.state == .idle)
        #expect(lyrics.task == nil)
        lyrics.load(videoID: nil)
        #expect(lyrics.state == .idle)
        #expect(lyrics.task == nil)
    }

    @Test func anOldTrackResponseCannotReplaceTheNewTrackLyrics() async {
        let gate = LyricsGate()
        let lyrics = LyricsSession { try await gate.fetch($0) }
        lyrics.load(videoID: "first")
        let first = lyrics.task
        await gate.waitForRequest("first")
        lyrics.load(videoID: "second")
        let second = lyrics.task
        await gate.waitForRequest("second")
        await gate.respond("second", with: .plain(text: "Second synthetic lyric", source: "Fixture"))
        await second?.value
        await gate.respond("first", with: .plain(text: "Stale synthetic lyric", source: "Fixture"))
        await first?.value
        #expect(lyrics.videoID == "second")
        #expect(lyrics.state == .available(.plain(text: "Second synthetic lyric", source: "Fixture")))
    }

    @Test func accountOrPanelClearDropsEvenAnUncancellableResponse() async {
        let gate = LyricsGate()
        let lyrics = LyricsSession { try await gate.fetch($0) }
        lyrics.load(videoID: "private-track")
        let request = lyrics.task
        await gate.waitForRequest("private-track")
        lyrics.clear()
        await gate.respond("private-track", with: .plain(text: "Private stale lyric", source: "Fixture"))
        await request?.value
        #expect(lyrics.videoID == nil)
        #expect(lyrics.state == .idle)
        #expect(lyrics.task == nil)
    }

    @Test func retryKeepsTheExactTrackAndUnavailableIsAnHonestState() async {
        let gate = LyricsGate()
        let lyrics = LyricsSession { try await gate.fetch($0) }
        lyrics.load(videoID: "same-track")
        let failed = lyrics.task
        await gate.waitForRequest("same-track")
        await gate.fail("same-track", with: MusicLyricsError.timedOut)
        await failed?.value
        #expect(lyrics.state == .failed("Loading lyrics timed out. Try again."))
        lyrics.retry()
        let retried = lyrics.task
        await gate.waitForRequest("same-track", count: 2)
        await gate.respond("same-track", with: .unavailable)
        await retried?.value
        #expect(lyrics.state == .unavailable)
        #expect(await gate.requests == ["same-track", "same-track"])
    }

    @Test func arbitraryErrorsNeverExposeTheirTextInThePanel() async {
        struct PrivateError: LocalizedError {
            var errorDescription: String? { "private token and account data" }
        }
        let lyrics = LyricsSession { _ in throw PrivateError() }
        lyrics.load(videoID: "test-track")
        await lyrics.task?.value
        #expect(lyrics.state == .failed("Could not load lyrics. Try again."))
    }
}

private actor LyricsGate {
    private var waiting: [String: CheckedContinuation<MusicLyrics, any Error>] = [:]
    private var arrivals: [String: [(Int, CheckedContinuation<Void, Never>)]] = [:]
    private(set) var requests: [String] = []

    func fetch(_ id: String) async throws -> MusicLyrics {
        requests.append(id)
        let count = requests.filter { $0 == id }.count
        let ready = arrivals[id, default: []].filter { $0.0 <= count }
        arrivals[id] = arrivals[id, default: []].filter { $0.0 > count }
        ready.forEach { $0.1.resume() }
        return try await withCheckedThrowingContinuation { waiting[id] = $0 }
    }

    func waitForRequest(_ id: String, count: Int = 1) async {
        if requests.filter({ $0 == id }).count >= count { return }
        await withCheckedContinuation { arrivals[id, default: []].append((count, $0)) }
    }

    func respond(_ id: String, with lyrics: MusicLyrics) { waiting.removeValue(forKey: id)?.resume(returning: lyrics) }
    func fail(_ id: String, with error: any Error) { waiting.removeValue(forKey: id)?.resume(throwing: error) }
}
