import AppKit
import Darwin
import Foundation
import MusicCore
import SwiftUI
import YouTubeMusic

enum SceneCheckLaunch {
    static let isRequested = CommandLine.arguments.contains("--check-ui-scenes")

    static var identifier: UUID? {
        guard let index = CommandLine.arguments.firstIndex(of: "--check-id"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return UUID(uuidString: CommandLine.arguments[index + 1])
    }
}

/// Uses a fresh domain that the bundle-check script also removes after a crash.
final class SceneCheckPreferences: @unchecked Sendable {
    static let current: SceneCheckPreferences = {
        guard let identifier = SceneCheckLaunch.identifier else {
            FileHandle.standardError.write(Data("A UUID --check-id is required for the scene check.\n".utf8))
            exit(2)
        }
        return SceneCheckPreferences(identifier: identifier)
    }()

    let domain: String
    let defaults: UserDefaults

    init(identifier: UUID = UUID()) {
        domain = "io.github.z11r.ytmusicmac.scenecheck.\(identifier.uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else {
            fatalError("Could not create isolated scene-check preferences.")
        }
        self.defaults = defaults
        defaults.set("system", forKey: "appearance")
    }

    func remove() { defaults.removePersistentDomain(forName: domain) }
}

actor SceneCheckTransport: MusicHTTPTransport {
    private(set) var attempts = 0
    func send(_ request: URLRequest) async throws -> MusicHTTPResponse {
        attempts += 1
        throw URLError(.notConnectedToInternet)
    }
}

enum SceneCheckFixture {
    static let tracks = [
        Track(id: "scene-track-a", title: "First Song", artist: "Test Artist", duration: 180),
        Track(id: "scene-track-b", title: "Second Song", artist: "Test Artist", duration: 210),
        Track(id: "scene-track-a", title: "First Song", artist: "Test Artist", duration: 180),
    ]
    static let page = MusicPage(title: "Home", sections: [
        MusicSection(id: "scene-fixture", title: "Music", items: tracks.map(MusicItem.track)),
    ], items: [])
}

/// A revision counts only after a view attached to a window acknowledges it.
struct SceneCheckProgress {
    static let target = 100
    private(set) var requested = 0
    private(set) var rendered = 0

    mutating func requestNext() -> Int? {
        guard requested == rendered, requested < Self.target else { return nil }
        requested += 1
        return requested
    }

    @discardableResult
    mutating func acknowledge(_ revision: Int, attached: Bool) -> Bool {
        guard attached, revision == requested, revision == rendered + 1 else { return false }
        rendered = revision
        return true
    }

    var isComplete: Bool { requested == Self.target && rendered == Self.target }
}

/// The watchdog runs off the main thread so a blocked UI cannot leave the check running.
/// Progress is shared with it so that a timeout reports how far the check got.
private final class SceneCheckCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let preferences: SceneCheckPreferences
    private let started = ContinuousClock.now
    private var rendered = 0
    private var milestones: [String: Int] = [:]
    private var windowVisible: Bool?
    private var lastHeartbeat: Int?
    private var windows: [String] = []

    init(preferences: SceneCheckPreferences) { self.preferences = preferences }

    private var elapsedMilliseconds: Int {
        let elapsed = ContinuousClock.now - started
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Records the first time a milestone is reached, in milliseconds since the driver was created.
    func record(_ milestone: String) {
        let milliseconds = elapsedMilliseconds
        lock.lock()
        defer { lock.unlock() }
        if milestones[milestone] == nil { milestones[milestone] = milliseconds }
    }

    /// Records that the main run loop is responsive, with the class names and visibility of its windows.
    func heartbeat(windows: [String]) {
        let milliseconds = elapsedMilliseconds
        lock.lock()
        defer { lock.unlock() }
        if milestones["mainRunLoop"] == nil { milestones["mainRunLoop"] = milliseconds }
        lastHeartbeat = milliseconds
        self.windows = windows
    }

    func record(rendered: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.rendered = rendered
    }

    func record(windowVisible: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if self.windowVisible == nil { self.windowVisible = windowVisible }
    }

    func finish(success: Bool, reason: String) -> Never {
        lock.lock()
        // Hold the lock through exit so timeout and normal completion cannot race cleanup.
        preferences.remove()
        var result: [String: Any] = ["check": "ui-scenes", "passed": success, "reason": reason,
                                     "renderedRevisions": rendered, "milestonesMs": milestones]
        if let windowVisible { result["windowVisible"] = windowVisible }
        if !success {
            result["windows"] = windows
            if let lastHeartbeat { result["lastMainHeartbeatMs"] = lastHeartbeat }
        }
        let data = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data()
        FileHandle.standardOutput.write(data + Data([10]))
        exit(success ? 0 : 1)
    }
}

@MainActor
final class SceneCheckDriver {
    let transport = SceneCheckTransport()
    private let completion: SceneCheckCompletion
    private var progress = SceneCheckProgress()
    private var hasStarted = false
    private weak var window: NSWindow?

    /// Lets app launch code report milestones; set only while a scene check runs.
    static private(set) weak var current: SceneCheckDriver?

    init() {
        let completion = SceneCheckCompletion(preferences: SceneCheckPreferences.current)
        self.completion = completion
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 18) {
            completion.finish(success: false, reason: "timeout")
        }
        let heartbeat = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                let windows = NSApplication.shared.windows.prefix(8).map {
                    "\(type(of: $0))\($0.isVisible ? "(visible)" : "")"
                }
                completion.heartbeat(windows: windows)
            }
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        Self.current = self
    }

    func record(_ milestone: String) { completion.record(milestone) }

    func rendered(_ revision: Int, in window: NSWindow?) {
        guard let window, window.contentView != nil else { return }
        if self.window == nil { completion.record("windowAttached") }
        self.window = window
        if progress.acknowledge(revision, attached: true) { completion.record(rendered: progress.rendered) }
    }

    func start(session: AppSession) {
        guard !hasStarted else { return }
        hasStarted = true
        completion.record("sessionStarted")
        Task { @MainActor in
            while window == nil { try? await Task.sleep(for: .milliseconds(10)) }
            completion.record("revisionsStarted")
            completion.record(windowVisible: window?.occlusionState.contains(.visible) ?? false)
            for _ in 0..<SceneCheckProgress.target {
                guard session.sceneCheckIsIsolated,
                      let revision = progress.requestNext(), session.advanceSceneCheck(to: revision) else {
                    completion.finish(success: false, reason: "isolation-or-state")
                }
                while progress.rendered < revision {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                window?.contentView?.layoutSubtreeIfNeeded()
                // Each revision gets a separate event-loop turn; batching them can hide Scene failures.
                try? await Task.sleep(for: .milliseconds(30))
            }
            let attempts = await transport.attempts
            let authenticated = await session.account.credentials.snapshot().isAuthenticated
            guard progress.isComplete, window != nil, session.sceneCheckIsIsolated,
                  attempts == 0, !authenticated else {
                completion.finish(success: false, reason: "isolation-or-render")
            }
            completion.record("revisionsFinished")
            completion.finish(success: true, reason: "completed")
        }
    }
}

struct SceneCheckRenderProbe: NSViewRepresentable {
    let driver: SceneCheckDriver
    let revision: Int

    func makeNSView(context: Context) -> ProbeView { ProbeView(driver: driver) }
    func updateNSView(_ view: ProbeView, context: Context) {
        view.revision = revision
        driver.rendered(revision, in: view.window)
    }

    final class ProbeView: NSView {
        let driver: SceneCheckDriver
        var revision = 0
        init(driver: SceneCheckDriver) {
            self.driver = driver
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            driver.rendered(revision, in: window)
        }
    }
}
