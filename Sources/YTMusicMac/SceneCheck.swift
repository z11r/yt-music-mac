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
private final class SceneCheckCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let preferences: SceneCheckPreferences

    init(preferences: SceneCheckPreferences) { self.preferences = preferences }

    func finish(success: Bool, reason: String, rendered: Int) -> Never {
        lock.lock()
        // Hold the lock through exit so timeout and normal completion cannot race cleanup.
        preferences.remove()
        let result: [String: Any] = ["check": "ui-scenes", "passed": success,
                                    "reason": reason, "renderedRevisions": rendered]
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

    init() {
        let completion = SceneCheckCompletion(preferences: SceneCheckPreferences.current)
        self.completion = completion
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 18) {
            completion.finish(success: false, reason: "timeout", rendered: 0)
        }
    }

    func rendered(_ revision: Int, in window: NSWindow?) {
        guard let window, window.contentView != nil else { return }
        self.window = window
        progress.acknowledge(revision, attached: true)
    }

    func start(session: AppSession) {
        guard !hasStarted else { return }
        hasStarted = true
        Task { @MainActor in
            while window == nil { try? await Task.sleep(for: .milliseconds(10)) }
            for _ in 0..<SceneCheckProgress.target {
                guard session.sceneCheckIsIsolated,
                      let revision = progress.requestNext(), session.advanceSceneCheck(to: revision) else {
                    completion.finish(success: false, reason: "isolation-or-state", rendered: progress.rendered)
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
                completion.finish(success: false, reason: "isolation-or-render", rendered: progress.rendered)
            }
            completion.finish(success: true, reason: "completed", rendered: progress.rendered)
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
