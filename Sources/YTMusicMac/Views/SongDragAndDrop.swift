import MusicCore
import SwiftUI

struct SongDragSource: ViewModifier {
    let tracks: [Track]
    let scope: UUID

    @ViewBuilder func body(content: Content) -> some View {
        if tracks.isEmpty { content }
        else { content.draggable(SongTransfer(tracks: tracks, scope: scope)) }
    }
}

struct QueueSongDropTarget: ViewModifier {
    let session: AppSession
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        let scope = session.libraryEditingScope
        content
            .dropDestination(for: SongTransfer.self) { items, _ in
                guard session.libraryEditingScope == scope,
                      let tracks = SongTransfer.acceptedTracks(items, expectedScope: scope) else { return false }
                session.addToQueue(tracks)
                return true
            } isTargeted: { isTargeted = $0 }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2)
                        .padding(2).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}
