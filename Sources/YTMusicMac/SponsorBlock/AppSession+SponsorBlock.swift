import Foundation
import MusicCore

extension AppSession {
    func seekSponsorBlockSection(_ section: SponsorBlockSection, context: SponsorBlockContext) async -> Bool {
        guard sponsorBlockContext == context else { return false }
        let reply = SponsorBlockSeekReply()
        let guardValue = SponsorBlockSeek(playback: context.playback, start: section.start, end: section.end)
        return await withTaskCancellationHandler {
            await reply.wait { finish in seek(to: section.end, sectionGuard: guardValue, completion: finish) }
        } onCancel: { Task { @MainActor in reply.finish(false) } }
    }

    var sponsorBlockContext: SponsorBlockContext? {
        guard acceptsProfileActions, account.isSignedIn, wantsPlayback,
              let track = currentTrack, let identity = player.confirmedSegmentIdentity,
              queue.accepts(identity.occurrence), identity.occurrence.trackID == track.id,
              identity.duration.isFinite, identity.duration > 0, identity.duration <= 43_200 else { return nil }
        return SponsorBlockContext.make(track: track, playback: identity, accountGeneration: accountGeneration)
    }
}
