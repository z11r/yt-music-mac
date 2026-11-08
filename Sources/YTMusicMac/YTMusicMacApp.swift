import AppKit
import Darwin
import SwiftUI

@main @MainActor
struct YTMusicMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var session: AppSession
    @State private var keyboardFocus: KeyboardFocusMonitor
    private let sceneCheck: SceneCheckDriver?
    @AppStorage("appearance", store: AppIdentity.preferences) private var appearance = "system"

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
            guard Bundle.main.bundleIdentifier == AppIdentity.identifier,
                  bundle.pathExtension == "app",
                  resources.path.hasPrefix(bundle.path + "/"),
                  let script = AppIdentity.resourceBundle.url(forResource: "PlayerBridge", withExtension: "js"),
                  let content = try? String(contentsOf: script, encoding: .utf8), !content.isEmpty else {
                FileHandle.standardError.write(Data("App bundle validation failed.\n".utf8))
                exit(1)
            }
            print("App bundle validation passed.")
            exit(0)
        }
        let sceneCheck = SceneCheckLaunch.isRequested ? SceneCheckDriver() : nil
        self.sceneCheck = sceneCheck
        let session: AppSession
        if let sceneCheck {
            session = AppSession(configuration: .sceneCheck(preferences: SceneCheckPreferences.current.defaults,
                                                            transport: sceneCheck.transport))
        } else { session = AppSession() }
        sceneCheck?.record("sessionCreated")
        _session = State(initialValue: session)
        let keyboardFocus = KeyboardFocusMonitor()
        keyboardFocus.start()
        _keyboardFocus = State(initialValue: keyboardFocus)
        AppScripting.session = sceneCheck == nil ? session : nil
    }

    private var colorScheme: ColorScheme? {
        appearance == "dark" ? .dark : appearance == "light" ? .light : nil
    }

    var body: some Scene {
        Window(AppIdentity.displayName, id: "main") {
            MainSceneView(session: session, delegate: delegate, sceneCheck: sceneCheck)
                .preferredColorScheme(colorScheme)
                .frame(minWidth: 860, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) { }
            PlaybackCommands(session: session, keyboardFocus: keyboardFocus)
            NavigationCommands(session: session)
            CommandGroup(after: .sidebar) {
                Button(session.showsQueue ? "Hide Queue" : "Show Queue") { session.showsQueue.toggle() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                PlayerWindowCommands()
            }
            MusicSearchCommands()
        }
        Window("Mini Player", id: "mini-player") {
            MiniPlayerView(session: session).preferredColorScheme(colorScheme)
        }
        .defaultSize(width: 360, height: 180)
        .windowResizability(.contentSize)
        MenuBarExtra("YT Music for Mac", systemImage: "music.note") {
            MenuBarPlayerView(session: session).preferredColorScheme(colorScheme)
        }.menuBarExtraStyle(.window)
        Settings {
            SettingsView(session: session).preferredColorScheme(colorScheme)
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
    let delegate: AppDelegate
    let sceneCheck: SceneCheckDriver?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RootView(session: session)
            .background {
                if let sceneCheck {
                    SceneCheckRenderProbe(driver: sceneCheck, revision: session.sceneCheckRevision)
                        .frame(width: 0, height: 0)
                }
            }
            .task {
                delegate.session = session
                delegate.openMainWindow = { openWindow(id: "main") }
                await session.start()
                sceneCheck?.start(session: session)
            }
    }
}

private struct PlayerWindowCommands: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Show Main Window") { openWindow(id: "main") }
            .keyboardShortcut("0", modifiers: .command)
        Button("Show Mini Player") { openWindow(id: "mini-player") }
            .keyboardShortcut("m", modifiers: [.command, .shift])
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var session: AppSession?
    var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        SceneCheckDriver.current?.record("didFinishLaunching")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session else { return .terminateNow }
        Task {
            await session.shutdown()
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
            (session?.player.isPlaying == true ? "Pause" : "Play", #selector(togglePlayback)),
            ("Next Song", #selector(nextSong)),
            ("Show Main Window", #selector(showMainWindow)),
        ]
        for (title, action) in entries {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func togglePlayback() { session?.togglePlayback() }
    @objc private func nextSong() { session?.next() }
    @objc private func showMainWindow() { openMainWindow?(); NSApp.activate(ignoringOtherApps: true) }
}
