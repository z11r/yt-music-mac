import Foundation
import MusicCore

extension AppSession {
    var lyricsTranslationTarget: LyricsTranslationTarget? {
        guard acceptsProfileActions, !account.isWorking, let track = currentTrack, track.isServiceTrack,
              let entry = queue.currentEntryID, let source = lyrics.translationSource, source.videoID == track.id else { return nil }
        return .init(id: UUID(), profile: playbackProfileGeneration, account: accountGeneration,
                     entry: entry, occurrence: queue.currentOccurrence, source: source)
    }
    func acceptsLyricsTranslation(_ target: LyricsTranslationTarget) -> Bool {
        acceptsProfileActions && !account.isWorking && currentTrack?.isServiceTrack == true && currentTrack?.id == target.source.videoID
            && target.matches(profile: playbackProfileGeneration, account: accountGeneration, entry: queue.currentEntryID,
                              occurrence: queue.currentOccurrence, source: lyrics.translationSource)
    }
    @discardableResult func openLyricsTranslation(_ target: LyricsTranslationTarget) -> Bool {
        guard acceptsLyricsTranslation(target) else { return false }
        return lyrics.translation.open(target) { [weak self] in self?.acceptsLyricsTranslation(target) == true }
    }
}
