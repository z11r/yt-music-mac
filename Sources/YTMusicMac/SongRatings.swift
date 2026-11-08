import Foundation
import Observation
import YouTubeMusic

/// Account-local rating state. Unknown values stay absent; an uncertain write
/// invalidates the old value instead of pretending the song became neutral.
@MainActor @Observable
final class SongRatings {
    struct ReadToken: Sendable {
        fileprivate let account: UUID
        fileprivate let revision: UInt64
        fileprivate let sequence: UInt64
    }

    private(set) var values: [String: MusicRating] = [:]
    @ObservationIgnored private var account = UUID()
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var readSequence: UInt64 = 0
    @ObservationIgnored private var changedAt: [String: UInt64] = [:]
    @ObservationIgnored private var observedAt: [String: UInt64] = [:]

    func beginRead() -> ReadToken {
        readSequence &+= 1
        return ReadToken(account: account, revision: revision, sequence: readSequence)
    }

    func observe(_ ratings: [String: MusicRating], from token: ReadToken) {
        guard token.account == account else { return }
        for (id, rating) in ratings where (changedAt[id] ?? 0) <= token.revision &&
            (observedAt[id] ?? 0) <= token.sequence {
            values[id] = rating
            observedAt[id] = token.sequence
        }
    }

    func confirm(_ rating: MusicRating, for videoID: String) {
        revision &+= 1
        values[videoID] = rating
        changedAt[videoID] = revision
    }

    func invalidate(_ videoID: String) {
        revision &+= 1
        values[videoID] = nil
        changedAt[videoID] = revision
    }

    func clear() {
        account = UUID()
        revision = 0
        readSequence = 0
        values.removeAll()
        changedAt.removeAll()
        observedAt.removeAll()
    }
}
