import Foundation
import MusicCore
import YouTubeMusic

extension AppSession {
    var recordingCounterpartTarget: RecordingCounterpartTarget? {
        guard acceptsProfileActions, account.isSignedIn, !account.isWorking,
              let track = currentTrack, let entry = queue.currentEntryID, let occurrence = queue.currentOccurrence else { return nil }
        let target = RecordingCounterpartTarget(profile: playbackProfileGeneration, account: accountGeneration,
            queueRevision: queue.revision, entry: entry, occurrence: occurrence, track: track)
        return target.isValid ? target : nil
    }

    @discardableResult func openRecordingCounterpart(_ target: RecordingCounterpartTarget) -> Bool {
        guard recordingCounterpartTarget == target else { return false }
        return recordingCounterpart.open(target, isCurrent: { [weak self] in self?.recordingCounterpartTarget == $0 },
            accept: { [weak self] owner, track in self?.acceptRecordingCounterpart(track, owner: owner) == true })
    }

    private func acceptRecordingCounterpart(_ track: Track, owner: RecordingCounterpartOwner) -> Bool {
        guard recordingCounterpartTarget == owner.target, !isSceneCheck else { return false }
        // Insert and select the exact new UUID; never replace the user's queue.
        guard let entryID = RecordingCounterpartQueueAction.insert(track, into: &queue, for: owner.target) else { return false }
        selectQueueEntry(entryID)
        return queue.currentOccurrence?.entryID == entryID && queue.currentOccurrence?.trackID == track.id
    }
}

/// The ordinary queue insertion, with exact review identity checked before editing.
enum RecordingCounterpartQueueAction {
    static func insert(_ track: Track, into queue: inout PlaybackQueue, for target: RecordingCounterpartTarget) -> UUID? {
        guard target.isValid, queue.revision == target.queueRevision, queue.currentEntryID == target.entry,
              queue.currentOccurrence == target.occurrence, queue.currentTrack == target.track, queue.entries.count < 10_000,
              track.isServiceTrack, track.origin == .catalog, track.contentKind == .song,
              RecordingCounterpartTarget.isVideoID(track.id), track.id != target.track.id else { return nil }
        return queue.playNext([track]).first?.id
    }
}
