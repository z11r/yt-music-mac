import MusicCore
import SwiftUI
import WebKit
import YouTubeMusic

struct RootView: View {
    @Bindable var session: AppSession

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(selection: destinationSelection) {
                    Section("Browse") {
                        Label("Home", systemImage: "house").tag(MusicDestination.home)
                        Label("Explore", systemImage: "safari").tag(MusicDestination.explore)
                    }
                    Section("Your Library") {
                        Label("Library", systemImage: "square.stack").tag(MusicDestination.library)
                        Label("Liked Songs", systemImage: "heart").tag(MusicDestination.likedSongs)
                    }
                }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
                .navigationTitle("YT Music")
            } detail: {
                VStack(spacing: 0) {
                    MusicContentView(session: session)
                    EmbeddedPlayerPanel(session: session)
                }
                .navigationTitle(session.destination.title)
            }
            .searchable(text: $session.searchText, placement: .toolbar, prompt: "Search music")
            .onSubmit(of: .search) { session.search() }
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button("Back", systemImage: "chevron.left", action: session.goBack)
                        .disabled(!session.canGoBack)
                    Button("Forward", systemImage: "chevron.right", action: session.goForward)
                        .disabled(!session.canGoForward)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Account", systemImage: session.account.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle",
                           action: session.openAccount)
                        .help(session.account.isSignedIn ? "Your YouTube Music account" : "Sign in to YouTube Music")
                    Button(session.showsQueue ? "Hide Queue" : "Show Queue", systemImage: "list.bullet") {
                        session.showsQueue.toggle()
                    }
                    .accessibilityValue(session.showsQueue ? "Shown" : "Hidden")
                }
            }
            .inspector(isPresented: $session.showsQueue) {
                QueueView(session: session)
                    .inspectorColumnWidth(min: 260, ideal: 310, max: 420)
            }
            Divider()
            PlayerBar(session: session)
        }
        .frame(minWidth: 860, minHeight: 600)
        .sheet(isPresented: $session.showsAccount, onDismiss: session.closeAccount) {
            AccountView(session: session)
        }
        .task { await session.start() }
    }

    private var destinationSelection: Binding<MusicDestination?> {
        Binding(get: { session.destination }, set: { value in
            if let value, value != session.destination { session.navigate(to: value) }
        })
    }
}

private struct EmbeddedPlayerPanel: View {
    @Bindable var session: AppSession

    var body: some View {
        VStack(spacing: 0) {
            if session.showsWebPlayer {
                Divider()
                HStack {
                    Label("YouTube Music Player", systemImage: "play.rectangle")
                        .font(.headline)
                    Spacer()
                    Button("Hide", systemImage: "xmark") { session.showsWebPlayer = false }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .padding(12)
            }
            // Keep one host attached for the lifetime of the main window. Its
            // player owns the WebKit view; secondary windows never host it.
            ExistingWebView(webView: session.player.webView)
                .frame(height: session.showsWebPlayer ? 320 : 1)
                .opacity(session.showsWebPlayer ? 1 : 0)
                .allowsHitTesting(session.showsWebPlayer)
                .accessibilityHidden(!session.showsWebPlayer)
        }
    }
}

struct ExistingWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct AccountView: View {
    @Bindable var session: AppSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle").font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your YouTube Music account").font(.headline)
                    Text("Complete sign-in on Google's page below.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if session.account.isWorking { ProgressView().controlSize(.small) }
                Button("Done", action: session.closeAccount).keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            if let message = session.account.errorMessage {
                InlineMessage(message: message, actionTitle: "Try Again", action: session.openAccount)
            }
            if let view = session.account.loginWebView {
                ExistingWebView(webView: view)
            } else {
                ContentUnavailableView("Account Closed", systemImage: "person.crop.circle",
                                       description: Text("Open your account again to sign in."))
            }
        }
        .frame(minWidth: 680, idealWidth: 800, minHeight: 560, idealHeight: 700)
    }
}

struct InlineMessage: View {
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer(minLength: 8)
            if let actionTitle, let action { Button(actionTitle, action: action) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
    }
}
