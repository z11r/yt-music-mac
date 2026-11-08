import AppKit
import CoreSpotlight
import Darwin
import SwiftUI

@main @MainActor
struct YTMusicMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var profiles: AppProfileOwner<NativeAppProfileRuntime>
    @State private var keyboardFocus: KeyboardFocusMonitor
    private let sceneCheck: SceneCheckDriver?
    private var session: AppSession { profiles.current.session }
    private var playbackBindings: PlaybackShortcutBindings { profiles.current.bindings }

    init() {
        if CommandLine.arguments.contains("--check-bundle") {
            _ = NSApplication.shared
            guard let dictionary = Bundle.main.url(forResource: "YTMusicMac", withExtension: "sdef"),
                  ScriptingDictionary.isRegistered(at: dictionary) else {
                FileHandle.standardError.write(Data("App scripting registration failed.\n".utf8))
                exit(1)
            }
            let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
            let resources = AppIdentity.resourceBundle.bundleURL.resolvingSymlinksInPath()
            let scriptsPresent = ["PlayerBridge", "EpisodeRateBridge"].allSatisfy { name in
                guard let url = AppIdentity.resourceBundle.url(forResource: name, withExtension: "js"),
                      let content = try? String(contentsOf: url, encoding: .utf8) else { return false }
                return !content.isEmpty
            }
            guard Bundle.main.bundleIdentifier == AppIdentity.identifier,
                  bundle.pathExtension == "app",
                  resources.path.hasPrefix(bundle.path + "/"), scriptsPresent else {
                FileHandle.standardError.write(Data("App bundle validation failed.\n".utf8))
                exit(1)
            }
            print("App bundle validation passed.")
            exit(0)
        }
        let sceneCheck = SceneCheckLaunch.isRequested ? SceneCheckDriver() : nil
        self.sceneCheck = sceneCheck
        let initialConfiguration: AppSessionConfiguration
        if let sceneCheck {
            initialConfiguration = .sceneCheck(preferences: SceneCheckPreferences.current.defaults,
                                                transport: sceneCheck.transport)
        } else {
            var configuration = AppSessionConfiguration.live()
            // Ownership is installed only after the registry has been read.
            configuration = AppSessionConfiguration.withoutSystemMedia(configuration)
            initialConfiguration = configuration
        }
        let initial = NativeAppProfileRuntime(profile: .original, configuration: initialConfiguration)
        let directory = sceneCheck == nil ? try? AppIdentity.applicationSupportDirectory() : nil
        let registry: any AppProfileRegistry = directory.map {
            AppProfileRegistryStore(io: FileAppProfileRegistryIO(file: $0.appendingPathComponent("app-profiles.json")))
        } ?? InitialOnlyAppProfileRegistry()
        let owner = AppProfileOwner(initial: initial, registry: registry, prepare: { profile, allowCreation in
            guard let directory, sceneCheck == nil else { throw AppProfileError.unavailable }
            return try await NativeAppProfileFactory(legacyDirectory: directory).prepare(profile, allowCreation: allowCreation)
        }, bind: { runtime, _ in
            AppScripting.session = sceneCheck == nil ? runtime?.session : nil
        })
        _profiles = State(initialValue: owner)
        sceneCheck?.record("sessionCreated")
        let keyboardFocus = KeyboardFocusMonitor()
        keyboardFocus.start()
        _keyboardFocus = State(initialValue: keyboardFocus)
        AppScripting.session = nil
        if sceneCheck == nil { MusicShortcutRegistration.register() }
    }

    private func surface<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        AppProfileSurface(runtime: profiles.current, activationID: profiles.activationID,
                          isSwitching: profiles.isSwitching || profiles.isLoading, content: content)
            .id(profiles.activationID)
    }

    var body: some Scene {
        Window(AppIdentity.displayName, id: "main") {
            surface {
                MainSceneView(session: session, profiles: profiles, delegate: delegate, sceneCheck: sceneCheck)
                    .frame(minWidth: 860, minHeight: 600)
            }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .newItem) {
                Button("Open Music Link…") { if session.acceptsProfileActions { session.links.showsSheet = true } }
                    .keyboardShortcut("o", modifiers: .command)
            }
            PlaybackCommands(session: session, keyboardFocus: keyboardFocus, bindings: playbackBindings)
            NavigationCommands(session: session)
            CommandGroup(after: .sidebar) {
                Button(session.showsQueue ? "Hide Queue" : "Show Queue") { if session.acceptsProfileActions { session.showsQueue.toggle() } }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                PlayerWindowCommands(session: session)
            }
            MusicSearchCommands()
        }
        Window("Mini Player", id: "mini-player") {
            surface { MiniPlayerView(session: session) }
        }
        .defaultSize(width: 360, height: 180)
        .windowResizability(.contentSize)
        Window("Now Playing", id: "now-playing") {
            surface { ExpandedPlayerView(session: session) }
        }
        .defaultSize(width: 520, height: 700)
        Window("Lyrics", id: "lyrics") {
            surface { LyricsPanel(session: session) }
        }
        .defaultSize(width: 560, height: 620)
        Window("Song Credits", id: "song-credits") {
            surface { SongCreditsPanel(session: session) }
        }
        .defaultSize(width: 560, height: 600)
        Window("Queue", id: "queue") {
            surface { QueueView(session: session).frame(minWidth: 300, minHeight: 360) }
        }
        .defaultSize(width: 380, height: 640)
        Window("Build a Queue", id: "catalog-queue-builder") {
            surface { CatalogQueueBuilderView(session: session) }
        }
        .defaultSize(width: 740, height: 740)
        MenuBarExtra("YT Music for Mac", systemImage: "music.note") {
            surface { MenuBarPlayerView(session: session) }
        }.menuBarExtraStyle(.window)
        Settings {
            surface {
                SettingsView(session: session, songNotifications: profiles.current.notifications,
                             playbackBindings: playbackBindings, profiles: sceneCheck == nil ? profiles : nil)
            }
        }
    }
}

private struct MusicSearchCommands: Commands {
    @FocusedValue(\.focusMusicSearch) private var focusMusicSearch

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Search Music") { focusMusicSearch?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(focusMusicSearch == nil)
        }
    }
}

private struct MainSceneView: View {
    let session: AppSession
    let profiles: AppProfileOwner<NativeAppProfileRuntime>
    let delegate: AppDelegate
    let sceneCheck: SceneCheckDriver?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RootView(session: session)
            .safeAreaInset(edge: .top) {
                if let error = profiles.errorMessage {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Local Profile Notice").font(.headline)
                        Text(error).font(.callout)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(.bar)
                        .accessibilityElement(children: .combine)
                }
            }
            .onOpenURL { url in
                openWindow(id: "main")
                session.receiveMusicLink(url)
            }
            .sheet(isPresented: Binding(get: { session.links.showsSheet }, set: { session.links.showsSheet = $0 })) {
                OpenMusicLinkSheet(session: session)
            }
            .alert("Could Not Open Music Link", isPresented: Binding(
                get: { session.links.error != nil },
                set: { if !$0 { session.links.error = nil } }
            )) {
                Button("OK", role: .cancel) { session.links.error = nil }
            } message: { Text(session.links.error ?? "") }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                      session.receiveSpotlightResult(identifier) else { return }
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .background {
                if let sceneCheck {
                    SceneCheckRenderProbe(driver: sceneCheck, revision: session.sceneCheckRevision)
                        .frame(width: 0, height: 0)
                }
            }
            .task(id: "\(profiles.activationID)-\(profiles.isSwitching)-\(profiles.isLoading)") {
                delegate.sessionProvider = { profiles.accepts(profiles.activationID) ? profiles.current.session : nil }
                delegate.shutdownOwner = { await profiles.shutdown() }
                let activation = profiles.activationID
                await profiles.start()
                guard !Task.isCancelled, profiles.accepts(activation), profiles.current.session === session else { return }
                delegate.session = session
                delegate.openMainWindow = { openWindow(id: "main") }
                let open = openWindow
                session.player.videoPresentation.didReturnToMain = { [weak session = session] in
                    guard profiles.accepts(activation), profiles.current.session === session else { return }
                    session?.showsWebPlayer = true
                    open(id: "main")
                }
                await session.start()
                guard !Task.isCancelled, profiles.accepts(activation), profiles.current.session === session else { return }
                session.links.isReady = sceneCheck == nil
                session.processPendingMusicLink()
                sceneCheck?.start(session: session)
            }
    }
}

private struct PlayerWindowCommands: View {
    let session: AppSession
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Show Main Window") { openWindow(id: "main") }
            .keyboardShortcut("0", modifiers: .command)
        Button("Show Mini Player") { openWindow(id: "mini-player") }
            .keyboardShortcut("m", modifiers: [.command, .shift])
        Button("Show Now Playing") { openWindow(id: "now-playing") }
        Button("Show Lyrics") { openWindow(id: "lyrics") }
        if let track = session.currentTrack {
            SongCreditsAction(track: track, session: session)
        }
        Button("Open Queue Window") { openWindow(id: "queue") }
        Button("Build a Queue from Searches…") {
            if session.acceptsProfileActions { openWindow(id: "catalog-queue-builder") }
        }
        KeepMiniPlayerOnTopToggle(preferences: session.preferences)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var session: AppSession?
    var sessionProvider: (() -> AppSession?)?
    var shutdownOwner: (() async -> Void)?
    private var activeSession: AppSession? { sessionProvider.map { $0() } ?? session }
    var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        SceneCheckDriver.current?.record("didFinishLaunching")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard shutdownOwner != nil || activeSession != nil else { return .terminateNow }
        Task {
            if let shutdownOwner { await shutdownOwner() }
            else { await activeSession?.shutdown() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow?()
        sender.activate(ignoringOtherApps: true)
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let entries: [(String, Selector)] = [
            (activeSession?.player.isPlaying == true ? AppLocalization.text("Pause") : AppLocalization.text("Play"), #selector(togglePlayback)),
            (AppLocalization.text("Next Song"), #selector(nextSong)),
            (AppLocalization.text("Show Main Window"), #selector(showMainWindow)),
        ]
        for (title, action) in entries {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func togglePlayback() { activeSession?.togglePlayback() }
    @objc private func nextSong() { activeSession?.next() }
    @objc private func showMainWindow() { openMainWindow?(); NSApp.activate(ignoringOtherApps: true) }
}
