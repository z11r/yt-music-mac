import AppKit
import SwiftUI

struct VideoPresentationMenu: View {
    let session: AppSession
    var body: some View {
        let presentation = session.player.videoPresentation
        Menu {
            Button(session.showsWebPlayer ? "Hide Web Player" : "Show Web Player") { session.showsWebPlayer.toggle() }
            Button("Open Video Window") { presentation.showWindow() }
            Button("Full Screen Player") { presentation.showWindow(fullScreen: true) }
            if presentation.isWindowPresented { Button("Return to Main Window", action: presentation.returnToMain) }
            Divider()
            Button(presentation.capabilities.isPictureInPictureActive ? "Exit Picture in Picture" : "Picture in Picture",
                   action: presentation.togglePictureInPicture)
                .disabled(!presentation.canRequestPictureInPicture)
            Divider()
            let counterpartTarget = session.recordingCounterpartTarget
            Button(RecordingCounterpartText.text("Other Recording…")) {
                if let counterpartTarget { _ = session.openRecordingCounterpart(counterpartTarget) }
            }.disabled(counterpartTarget == nil || session.recordingCounterpart.isBusy)
                .help(RecordingCounterpartText.text("Review a paired recording from YouTube Music. Playback starts at the beginning."))
        } label: { Label("Video", systemImage: "play.rectangle") }
        .menuStyle(.borderlessButton).fixedSize().labelStyle(.iconOnly)
        .help("Video presentation options")
        .disabled(session.currentTrack?.isServiceTrack != true || session.player.activeKind != .web)
        .sheet(isPresented: Binding(get: { session.recordingCounterpart.isPresented }, set: { if !$0 { session.recordingCounterpart.clear() } })) {
            RecordingCounterpartPanel(session: session.recordingCounterpart)
        }
        .onChange(of: session.recordingCounterpartTarget) { _, _ in session.recordingCounterpart.discardIfStale() }
        .onDisappear { session.recordingCounterpart.clear() }
    }
}

struct PlaybackWebViewAnchor: NSViewRepresentable {
    let presentation: VideoPresentationController
    let generation: Int
    let visible: Bool

    func makeCoordinator() -> Coordinator { Coordinator(presentation) }
    func makeNSView(context: Context) -> NSView {
        let anchor = NSView()
        presentation.attachInline(anchor, visible: visible)
        return anchor
    }
    func updateNSView(_ anchor: NSView, context: Context) {
        presentation.attachInline(anchor, visible: visible)
    }
    static func dismantleNSView(_ anchor: NSView, coordinator: Coordinator) { coordinator.presentation.detachInline(anchor) }
    final class Coordinator {
        let presentation: VideoPresentationController
        init(_ presentation: VideoPresentationController) { self.presentation = presentation }
    }
}
