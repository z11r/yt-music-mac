import Foundation
import Testing
@testable import MusicCore

@Suite("Manual local completion metadata")
struct ManualEpisodeCompletionTests {
    private let episode = EpisodeIdentity(browseID: "MPEDfixture")
    @Test func oldRecordsDecodeWithUnknownCompletionSourceAndManualZeroIsExplicit() throws {
        let old = EpisodeProgressRecord(episode: episode, position: 30, duration: 100, completed: false, updatedAt: Date(timeIntervalSince1970: 100))
        let data = try JSONEncoder().encode(old)
        #expect(!String(decoding: data, as: UTF8.self).contains("completionSource"))
        #expect(try JSONDecoder().decode(EpisodeProgressRecord.self, from: data).completionSource == nil)
        let manual = EpisodeProgressRecord(episode: episode, position: 0, duration: 100, completed: true,
            updatedAt: old.updatedAt, completionSource: .manual)
        let snapshot = EpisodeProgressSnapshot(accountHash: String(repeating: "a", count: 64), records: [manual])
        try snapshot.validate()
        let decoded = try JSONDecoder().decode(EpisodeProgressSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.records == snapshot.records && decoded.accountHash == snapshot.accountHash && decoded.settings == snapshot.settings)
        #expect(manual.position == 0 && manual.duration == 100 && manual.completed)
    }
    @Test func zeroIsNotAcceptedAsMeasuredProgressOrWithoutKnownDuration() {
        for (position, duration, completed, source) in [
            (0.0, 100.0, true, EpisodeCompletionSource?.none), (0, 100, false, .manual),
            (0, 0, true, .manual), (0, .nan, true, .manual), (-1, 100, true, .manual), (101, 100, false, .manual)
        ] {
            let record = EpisodeProgressRecord(episode: episode, position: position, duration: duration, completed: completed,
                updatedAt: Date(timeIntervalSince1970: 100), completionSource: source)
            #expect(throws: EpisodeProgressError.invalidSnapshot) {
                try EpisodeProgressSnapshot(accountHash: String(repeating: "a", count: 64), records: [record]).validate()
            }
        }
    }
}
