import AppKit
import CoreSpotlight
import Darwin
import SwiftUI
import YouTubeMusic

@main @MainActor
struct YTMusicMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var profiles: AppProfileOwner<NativeAppProfileRuntime>
    @State private var keyboardFocus: KeyboardFocusMonitor
    private let sceneCheck: SceneCheckDriver?
    private let startupPreferences: StartupWindowPreferences
    private var startup: AppLaunchCoordinator { delegate.launchCoordinator! }
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
        let supportsWindowSelection: Bool
        if #available(macOS 15, *) { supportsWindowSelection = true } else { supportsWindowSelection = false }
        startupPreferences = StartupWindowPreferences(access: .defaults(sceneCheck == nil ? AppIdentity.preferences : SceneCheckPreferences.current.defaults),
            supportsSelection: supportsWindowSelection, launchOverride: sceneCheck == nil ? nil : (SceneCheckLaunch.startupPolicy ?? .main))
        let directory = sceneCheck == nil ? try? AppIdentity.applicationSupportDirectory() : nil
        let registry: any AppProfileRegistry = directory.map {
            AppProfileRegistryStore(io: FileAppProfileRegistryIO(file: $0.appendingPathComponent("app-profiles.json")))
        } ?? InitialOnlyAppProfileRegistry()
        let outputAdmission = PlaybackOutputAdmission()
        let localAudioReferences = LocalAudioReferenceUseRegistryPool()
        let initialConfiguration: AppSessionConfiguration
        if let sceneCheck {
            initialConfiguration = .sceneCheck(preferences: SceneCheckPreferences.current.defaults,
                                                transport: sceneCheck.transport)
        } else {
            var configuration = AppSessionConfiguration.live()
            // Ownership is installed only after the registry has been read.
            configuration = AppSessionConfiguration.withoutSystemMedia(configuration)
            configuration.playbackOutputAdmission = outputAdmission
            if let directory,
               let context = try? AppProfileContext(profile: .original, appIdentifier: AppIdentity.identifier,
                   legacyDirectory: directory, legacyWebsiteDataIdentifier: AppIdentity.websiteDataIdentifier),
               let references = try? localAudioReferences.registry(for: context) {
                configuration.localAudioResources = LocalAudioSessionResources(context: context, registry: registry,
                    root: directory, references: references)
            }
            initialConfiguration = configuration
        }
        let initial = NativeAppProfileRuntime(profile: .original, configuration: initialConfiguration)
        let owner = AppProfileOwner(initial: initial, registry: registry, prepare: { profile, allowCreation in
            guard let directory, sceneCheck == nil else { throw AppProfileError.unavailable }
            return try await NativeAppProfileFactory(legacyDirectory: directory, registry: registry, outputAdmission: outputAdmission,
                localAudioReferences: localAudioReferences).prepare(profile, allowCreation: allowCreation)
        }, bind: { _, _ in
            // Revoke immediately; the process coordinator publishes only a ready activation.
            AppScripting.session = nil
        })
        if let directory, sceneCheck == nil { owner.installDeletionAdapter(NativeProfileCleanup(root: directory)) }
        _profiles = State(initialValue: owner)
        sceneCheck?.record("sessionCreated")
        let keyboardFocus = KeyboardFocusMonitor()
        keyboardFocus.start()
        _keyboardFocus = State(initialValue: keyboardFocus)
        AppScripting.session = nil
        if sceneCheck == nil { MusicShortcutRegistration.register() }
        let appDelegate = delegate
        let startupPreferences = startupPreferences
        let launch = AppLaunchCoordinator(policy: startupPreferences.launchPolicy, ownership: { [weak owner] in
            guard let owner else { return .init(activation: UUID(), ready: false) }
            let activation = owner.activationID
            let session = owner.current.session
            return .init(activation: activation, accountEpoch: session.accountGeneration,
                ready: owner.accepts(activation) && session.hasFinishedStartup && session.acceptsProfileActions)
        }, start: { [weak owner] in await owner?.start() }, activate: { [weak owner, weak appDelegate] activation in
            guard let owner, owner.accepts(activation), let appDelegate else { return }
            let session = owner.current.session
            appDelegate.session = session
            AppScripting.session = sceneCheck == nil ? session : nil
            session.links.isReady = sceneCheck == nil
            session.onLaunchContextChanged = { [weak owner, weak appDelegate] in
                guard let owner, owner.accepts(activation) else { return }
                appDelegate?.launchCoordinator?.ownershipChanged()
            }
            session.onAutomationNavigation = { [weak owner, weak appDelegate] in
                guard let owner, owner.accepts(activation) else { return }
                appDelegate?.launchCoordinator?.requestWindow(.main, expectedActivation: activation)
            }
            session.player.videoPresentation.didReturnToMain = { [weak owner, weak session, weak appDelegate] in
                guard let owner, owner.accepts(activation), owner.current.session === session else { return }
                session?.showsWebPlayer = true
                appDelegate?.launchCoordinator?.requestWindow(.main, expectedActivation: activation)
            }
            session.processPendingMusicLink()
            sceneCheck?.start(session: session, startup: appDelegate.launchCoordinator, reopenMain: { [weak appDelegate] in
                appDelegate?.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false) == false
            })
        }, receiveURL: { [weak owner] url, activation in
            guard let owner, owner.accepts(activation) else { return }
            owner.current.session.receiveMusicLink(url)
        }, receiveSpotlight: { [weak owner] identifier, activation in
            guard let owner, owner.accepts(activation) else { return false }
            return owner.current.session.receiveSpotlightResult(identifier)
        }, shutdown: { [weak owner] in await owner?.shutdown() }, recovery: NativeStartupRecoveryPresenter(),
        resetAndQuit: { startupPreferences.select(.system); NSApp.terminate(nil) },
        validateURL: { MusicLink(url: $0) != nil }, activateApplication: { NSApp.activate(ignoringOtherApps: true) })
        appDelegate.launchCoordinator = launch
        appDelegate.sessionProvider = { [weak owner, weak launch] in
            guard let owner, let activation = launch?.readyActivation, owner.accepts(activation),
                  owner.current.session.acceptsProfileActions else { return nil }
            return owner.current.session
        }
        appDelegate.shutdownOwner = { [weak launch] in await launch?.shutdown() }
        appDelegate.openMainWindow = { [weak launch] in launch?.requestWindow(.main) }
    }

    private func surface<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        AppProfileSurface(runtime: profiles.current, activationID: profiles.activationID,
                          isSwitching: profiles.isSwitching || profiles.isLoading, content: content)
            .id(profiles.activationID)
            .modifier(WindowActionBridge(coordinator: startup))
    }

    var body: some Scene {
        Window(AppIdentity.displayName, id: "main") {
            surface {
                MainSceneView(session: session, profiles: profiles, sceneCheck: sceneCheck)
                    .frame(minWidth: 860, minHeight: 600)
            }
        }
        .defaultSize(width: 1180, height: 780)
        .startupWindowPolicy(startupPreferences.launchPolicy, window: .main)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) { }
            if profiles.accepts(profiles.activationID) {
            CommandGroup(after: .newItem) {
                Button("Open Music Link…") { if session.acceptsProfileActions {
                    startup.requestWindow(.main, expectedActivation: profiles.activationID)
                    session.links.showsSheet = true
                } }
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
        }
        Window("Mini Player", id: "mini-player") {
            surface {
                MiniPlayerView(session: session).background {
                    if let sceneCheck { StartupMiniWindowProbe(driver: sceneCheck).frame(width: 0, height: 0) }
                }
            }
        }
        .defaultSize(width: 360, height: 180)
        .windowResizability(.contentSize)
        .startupWindowPolicy(startupPreferences.launchPolicy, window: .mini)
        Window("Now Playing", id: "now-playing") {
            surface { ExpandedPlayerView(session: session) }
        }
        .defaultSize(width: 520, height: 700)
        .startupWindowPolicy(startupPreferences.launchPolicy)
        Window("Lyrics", id: "lyrics") {
            surface { LyricsPanel(session: session) }
        }
        .defaultSize(width: 560, height: 620)
        .startupWindowPolicy(startupPreferences.launchPolicy)
        Window("Song Credits", id: "song-credits") {
            surface { SongCreditsPanel(session: session) }
        }
        .defaultSize(width: 560, height: 600)
        .startupWindowPolicy(startupPreferences.launchPolicy)
        Window("Queue", id: "queue") {
            surface { QueueView(session: session).frame(minWidth: 300, minHeight: 360) }
        }
        .defaultSize(width: 380, height: 640)
        .startupWindowPolicy(startupPreferences.launchPolicy)
        Window("Local Audio", id: "local-audio-library") {
            surface {
                if profiles.isLoading || profiles.isSwitching {
                    ProgressView("Loading profile…")
                } else if profiles.accepts(profiles.activationID), let library = session.localAudioLibrary {
                    LocalAudioLibraryWindowContent(controller: library)
                } else {
                    ContentUnavailableView("Local audio is unavailable", systemImage: "music.note.house",
                        description: Text("Local audio requires available storage for this profile."))
                }
            }
        }
        .defaultSize(width: 820, height: 660)
        .startupWindowPolicy(startupPreferences.launchPolicy)
        Window("Build a Queue", id: "catalog-queue-builder") {
            surface { CatalogQueueBuilderView(session: session) }
        }
        .defaultSize(width: 740, height: 740)
        .startupWindowPolicy(startupPreferences.launchPolicy)
        MenuBarExtra {
            surface { MenuBarPlayerView(session: session) }
        } label: {
            Image(systemName: "music.note")
                .accessibilityLabel(AppIdentity.displayName)
                .modifier(WindowActionBridge(coordinator: startup, statusLabel: true))
        }.menuBarExtraStyle(.window)
        Settings {
            surface {
                SettingsView(session: session, songNotifications: profiles.current.notifications,
                             playbackBindings: playbackBindings, profiles: sceneCheck == nil ? profiles : nil, startupPreferences: startupPreferences)
            }
        }.startupWindowPolicy(startupPreferences.launchPolicy)
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
            .sheet(isPresented: Binding(get: { session.links.showsSheet }, set: { session.links.showsSheet = $0 })) {
                OpenMusicLinkSheet(session: session)
            }
            .alert("Could Not Open Music Link", isPresented: Binding(
                get: { session.links.error != nil },
                set: { if !$0 { session.links.error = nil } }
            )) {
                Button("OK", role: .cancel) { session.links.error = nil }
            } message: { Text(session.links.error ?? "") }
            .background {
                if let sceneCheck {
                    SceneCheckRenderProbe(driver: sceneCheck, revision: session.sceneCheckRevision)
                        .frame(width: 0, height: 0)
                }
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
        Button("Open Local Audio…") {
            if session.acceptsProfileActions { openWindow(id: "local-audio-library") }
        }.disabled(session.localAudioLibrary == nil || !session.acceptsProfileActions)
        Button("Build a Queue from Searches…") {
            if session.acceptsProfileActions { openWindow(id: "catalog-queue-builder") }
        }
        KeepMiniPlayerOnTopToggle(preferences: session.preferences)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var launchCoordinator: AppLaunchCoordinator?
    weak var session: AppSession?
    var sessionProvider: (() -> AppSession?)?
    var shutdownOwner: (() async -> Void)?
    private var activeSession: AppSession? { sessionProvider.map { $0() } ?? session }
    var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        SceneCheckDriver.current?.record("didFinishLaunching")
        launchCoordinator?.start()
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
        guard !flag, let launchCoordinator else { return true }
        guard launchCoordinator.requestWindow(.main) else { return false }
        sender.activate(ignoringOtherApps: true)
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.count <= 16, let last = urls.last else { return }
        _ = launchCoordinator?.openURL(last)
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
        return launchCoordinator?.openSpotlight(identifier) == true
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
