import Foundation
import Observation
import SwiftUI
import YouTubeMusic

struct ArtistAboutScope: Equatable {
    let profile: UUID
    let account: UUID
    let destination: MusicDestination
    let about: MusicArtistAbout
    init?(profile: UUID, account: UUID, destination: MusicDestination, about: MusicArtistAbout?) {
        let artist: MusicCollection
        switch destination {
        case let .collection(value) where value.kind == .artist: artist = value
        case let .browse(reference) where reference.kind == .artist:
            artist = .init(id: reference.browseID, kind: .artist, title: reference.title)
        default: return nil
        }
        guard !artist.isUploaded, let about else { return nil }
        self.profile = profile; self.account = account; self.destination = destination; self.about = about
    }
}

struct ArtistAboutPresentation: Identifiable, Equatable {
    let id = UUID()
    let scope: ArtistAboutScope
}

/// Only an explicit, still-current button action can create a presentation.
@MainActor @Observable final class ArtistAboutPresentationState {
    private(set) var presentation: ArtistAboutPresentation?
    @discardableResult func open(_ candidate: ArtistAboutScope, isCurrent: (ArtistAboutScope) -> Bool) -> Bool {
        guard isCurrent(candidate) else { return false }
        presentation = .init(scope: candidate); return true
    }
    func current(for scope: ArtistAboutScope?) -> ArtistAboutPresentation? {
        guard let presentation, presentation.scope == scope else { return nil }
        return presentation
    }
    func dismiss(_ id: UUID) { if presentation?.id == id { presentation = nil } }
    func discardIfStale(current scope: ArtistAboutScope?) {
        if let presentation, presentation.scope != scope { dismiss(presentation.id) }
    }
}

struct ArtistAboutButton: View {
    let session: AppSession
    @State private var state = ArtistAboutPresentationState()
    private var currentScope: ArtistAboutScope? {
        guard session.acceptsProfileActions, !session.account.isWorking else { return nil }
        return .init(profile: session.playbackProfileGeneration, account: session.accountGeneration,
            destination: session.destination, about: session.page?.collectionHeader?.artistAbout)
    }
    var body: some View {
        let candidate = currentScope
        let displayed = state.current(for: candidate)
        Group { if let candidate {
            Button("About This Artist…", systemImage: "info.circle") {
                _ = state.open(candidate) { $0 == currentScope }
            }
            .buttonStyle(.borderless)
            .popover(item: Binding(get: { state.current(for: currentScope) }, set: { next in
                if next == nil, let displayed { state.dismiss(displayed.id) }
            })) { presentation in
                ArtistAboutPanel(about: presentation.scope.about, isCurrent: {
                    state.current(for: currentScope)?.id == presentation.id
                })
                .id(presentation.id)
                .onDisappear { state.dismiss(presentation.id) }
            }
        } }
        .onChange(of: currentScope) { _, _ in state.discardIfStale(current: currentScope) }
    }
}

private struct ArtistAboutPanel: View {
    let about: MusicArtistAbout
    let isCurrent: @MainActor () -> Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("About This Artist").font(.headline).accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isCurrent() {
                        Text(verbatim: about.text)
                        if !about.sourceURLs.isEmpty {
                            Text("Supplied Source Addresses").font(.subheadline.bold()).accessibilityAddTraits(.isHeader)
                            ForEach(about.sourceURLs, id: \.self) { value in Text(verbatim: value) }
                        }
                        Text("Provided by YouTube Music").font(.caption).foregroundStyle(.secondary)
                    } else { Text("Open this artist again to view current information.").foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }.padding(20).frame(width: 480, height: 340)
    }
}
