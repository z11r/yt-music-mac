import MusicCore
import SwiftUI

struct EpisodeLocalStatusActions: View {
    let track: Track
    let session: AppSession

    var body: some View {
        let generation = session.accountGeneration
        if track.contentKind == .podcastEpisode, track.episode != nil {
            let target = session.episodeStatusTarget(for: track)
            if session.episodePlayback.progress(for: track)?.completed == true {
                Text("Completed Locally")
            }
            Button("Mark Completed Locally") {
                guard let target else { return }
                _ = session.changeEpisodeLocalStatus(.markCompleted, track: track, target: target, expectedAccountGeneration: generation)
            }.disabled(target?.canMarkCompleted != true)
                .help("Playback continues. Local progress tracking resumes after an explicit seek or new playback.")
            Button("Clear Local Progress") {
                guard let target else { return }
                _ = session.changeEpisodeLocalStatus(.clearProgress, track: track, target: target, expectedAccountGeneration: generation)
            }.disabled(target?.canClearProgress != true)
                .help("Playback continues. Local progress tracking resumes after an explicit seek or new playback.")
        }
    }
}
