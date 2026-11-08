import AppKit
import MusicCore
import SwiftUI
import WebKit
import YouTubeMusic

struct RootView: View {
    @Bindable var session: AppSession
    @State private var isSearchPresented = false
    @FocusState private var isSearchFocused: Bool
    @State private var searchWindow = SearchWindowReference()
    @State private var libraryEditor: LibraryEditorRequest?

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
                        Label("Playlists", systemImage: "music.note.list").tag(MusicDestination.libraryCategory(.playlists))
                        Label("Albums", systemImage: "square.stack.fill").tag(MusicDestination.libraryCategory(.albums))
                        Label("Artists", systemImage: "person.2").tag(MusicDestination.libraryCategory(.artists))
                        Label("Liked Songs", systemImage: "heart").tag(MusicDestination.likedSongs)
                        Label("Listening History", systemImage: "clock").tag(MusicDestination.history)
                    }
                }
                .listStyle(.sidebar)
                .accessibilityLabel("Music navigation")
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
                .navigationTitle("YT Music")
            } detail: {
                VStack(spacing: 0) {
                    MusicContentView(session: session, presentEditor: libraryEditorPresenter)
                    EmbeddedPlayerPanel(session: session)
                }
                .navigationTitle(session.destination.title)
            }
            .searchable(text: $session.searchText, isPresented: $isSearchPresented,
                        placement: .toolbar, prompt: Text("Search music"))
            .modifier(CatalogSearchFocus(focus: $isSearchFocused))
            .onSubmit(of: .search) { session.submitSearch() }
            .onChange(of: session.searchText) { session.searchTextChanged() }
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button("Back", systemImage: "chevron.left", action: session.goBack)
                        .disabled(!session.canGoBack)
                    Button("Forward", systemImage: "chevron.right", action: session.goForward)
                        .disabled(!session.canGoForward)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    RecentSearchesMenu(session: session)
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
            if libraryEditor == nil { LibraryEditFeedbackView(session: session) }
            Divider()
            PlayerBar(session: session)
        }
        .frame(minWidth: 860, minHeight: 600)
        .background(SearchWindowAnchor(reference: searchWindow).frame(width: 0, height: 0))
        .background(SearchSuggestionsAttachment(session: session))
        .focusedSceneValue(\.focusMusicSearch, searchAction)
        .sheet(isPresented: $session.showsAccount, onDismiss: session.closeAccount) {
            AccountView(session: session)
        }
        .sheet(item: $libraryEditor) { request in
            LibraryEditorView(session: session, request: request)
        }
        .onChange(of: session.remoteLibraryEditingEnabled) {
            if !session.remoteLibraryEditingEnabled { libraryEditor = nil }
        }
        .onChange(of: session.libraryEditingScope) { libraryEditor = nil }
        .task { await session.start() }
    }

    private var searchAction: (() -> Void)? {
        guard !session.showsAccount, libraryEditor == nil else { return nil }
        return { focusSearch() }
    }

    private func presentLibraryEditor(_ request: LibraryEditorRequest) {
        guard session.remoteLibraryEditingEnabled, !session.isEditingLibrary, !session.showsAccount else { return }
        libraryEditor = request
    }

    private var libraryEditorPresenter: (LibraryEditorRequest) -> Void {
        let scope = session.libraryEditingScope
        return { request in
            guard session.libraryEditingScope == scope else { return }
            presentLibraryEditor(request)
        }
    }

    private func focusSearch() {
        isSearchPresented = true
        if #available(macOS 15, *) {
            isSearchFocused = true
        } else {
            Task { @MainActor in
                await Task.yield()
                searchWindow.focusSearchField()
            }
        }
    }

    private var destinationSelection: Binding<MusicDestination?> {
        Binding(get: { session.destination }, set: { value in
            if let value, value != session.destination { session.navigate(to: value) }
        })
    }
}

private struct MusicSearchActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var focusMusicSearch: (() -> Void)? {
        get { self[MusicSearchActionKey.self] }
        set { self[MusicSearchActionKey.self] = newValue }
    }
}

private struct CatalogSearchFocus: ViewModifier {
    let focus: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.searchFocused(focus) }
        else { content }
    }
}

@MainActor
private final class SearchWindowReference {
    weak var window: NSWindow?

    func focusSearchField() {
        guard let window,
              let item = window.toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first else { return }
        window.makeFirstResponder(item.searchField)
        item.searchField.selectText(nil)
    }
}

private struct SearchWindowAnchor: NSViewRepresentable {
    let reference: SearchWindowReference
    func makeNSView(context: Context) -> SearchAnchorView { SearchAnchorView(reference: reference) }
    func updateNSView(_ view: SearchAnchorView, context: Context) {}

    final class SearchAnchorView: NSView {
        let reference: SearchWindowReference
        init(reference: SearchWindowReference) {
            self.reference = reference
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference.window = window
        }
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
            // The player replaces the view to unload an idle page; the host
            // swaps it in place.
            // WebKit judges page visibility by the view's hidden state and its
            // window, not by size or opacity. A hidden page stops rendering and
            // slows its timers. The page stays visible while a song starts,
            // because WebKit can refuse to start media in a hidden page.
            let player = session.player
            ExistingWebView(webView: { [weak player] in player?.webView },
                            identity: player.webViewGeneration,
                            isHidden: !session.showsWebPlayer && !player.isStartingPlayback)
                .frame(width: session.showsWebPlayer ? nil : 1, height: session.showsWebPlayer ? 320 : 1)
                .opacity(session.showsWebPlayer ? 1 : 0)
                .allowsHitTesting(session.showsWebPlayer)
                .accessibilityHidden(!session.showsWebPlayer)
        }
    }
}

struct ExistingWebView: NSViewRepresentable {
    /// Looked up at update time. SwiftUI can keep old copies of this value (for
    /// example in toolbar bookkeeping), so it must not hold the web view itself:
    /// a stale copy would keep a replaced view and its page process alive.
    let webView: @MainActor () -> WKWebView?
    /// Changes with the provided web view so SwiftUI updates the host. Never
    /// the view itself, which a stale copy would keep alive.
    let identity: AnyHashable?
    var isHidden = false

    func makeNSView(context: Context) -> WebViewHost {
        let host = WebViewHost()
        host.show(webView(), hidden: isHidden)
        return host
    }

    func updateNSView(_ host: WebViewHost, context: Context) {
        host.show(webView(), hidden: isHidden)
    }
}

/// Holds the current web view as its only subview. Swapping in a replacement
/// removes the previous view, so nothing in the window keeps its page alive.
final class WebViewHost: NSView {
    func show(_ webView: WKWebView?, hidden: Bool) {
        guard let webView else {
            subviews.forEach { $0.removeFromSuperview() }
            return
        }
        if webView.superview !== self {
            subviews.forEach { old in
                // The key view loop holds linked views strongly.
                if let next = nextKeyView, next === old || next.isDescendant(of: old) { nextKeyView = nil }
                old.nextKeyView = nil
                old.removeFromSuperview()
            }
            webView.frame = bounds
            webView.autoresizingMask = [.width, .height]
            addSubview(webView)
        }
        if webView.isHidden != hidden { webView.isHidden = hidden }
    }
}

private struct AccountView: View {
    @Bindable var session: AppSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle").font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your YouTube Music account").font(.headline).accessibilityAddTraits(.isHeader)
                    Text(session.account.isSignedIn ? "Manage your account on Google's page below." : "Complete sign-in on Google's page below.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if session.account.isWorking {
                    ProgressView().controlSize(.small).accessibilityLabel("Checking account")
                }
                Button("Done", action: session.closeAccount).keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            if let message = session.account.errorMessage {
                InlineMessage(message: message, actionTitle: "Try Again", action: session.openAccount)
            }
            if let view = session.account.loginWebView {
                let account = session.account
                ExistingWebView(webView: { [weak account] in account?.loginWebView },
                                identity: AnyHashable(ObjectIdentifier(view)))
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
            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer(minLength: 8)
            if let actionTitle, let action { Button(actionTitle, action: action) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
    }
}
