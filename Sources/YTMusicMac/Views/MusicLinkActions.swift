import AppKit
import MusicCore
import SwiftUI
import YouTubeMusic

struct MusicLinkActions: View {
    let link: MusicLink?
    init(link: MusicLink) { self.link = link }
    init(track: Track) { link = track.origin == .upload ? nil : .track(track.id) }
    init(collection: MusicCollection) { link = collection.isUploaded ? nil : .collection(collection) }
    var body: some View {
        if let url = link?.url {
            ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
            Button("Copy Link", systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
            }
        }
    }
}

struct OpenMusicLinkSheet: View {
    let session: AppSession
    @State private var text = ""
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var url: URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              MusicLink(url: url) != nil else { return nil }
        return url
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open Music Link").font(.title2.bold())
            Text("Paste a YouTube Music song, album, artist, or playlist link.")
                .foregroundStyle(.secondary)
            TextField("Music link", text: $text)
                .textFieldStyle(.roundedBorder).focused($isFocused)
                .onSubmit(open)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open", action: open).keyboardShortcut(.defaultAction).disabled(url == nil)
            }
        }
        .padding(24).frame(width: 470)
        .onAppear { isFocused = true }
    }
    private func open() {
        guard let url else { return }
        session.receiveMusicLink(url)
        dismiss()
    }
}
