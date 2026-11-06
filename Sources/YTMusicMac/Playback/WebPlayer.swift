import Foundation
import MusicCore
import Observation
import WebKit

@MainActor
@Observable
final class WebPlayer: NSObject {
    let webView: WKWebView
    let clock = PlaybackClock()
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var errorMessage: String?
    private(set) var volume: Double = 1

    var playbackIntent: Bool { self.wantsPlaying }

    @ObservationIgnored var onEnded: ((PlaybackOccurrence) -> Void)?
    @ObservationIgnored var onFailure: (() -> Void)?
    @ObservationIgnored var onPageReady: ((WKWebView) -> Void)?
    @ObservationIgnored var onStateChanged: (() -> Void)?

    @ObservationIgnored private let messageHandler: PlayerMessageHandler
    @ObservationIgnored private var gate = PlaybackEventGate()
    @ObservationIgnored private var track: Track?
    @ObservationIgnored private var occurrence: PlaybackOccurrence?
    @ObservationIgnored private var navigation: WKNavigation?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var commandRevision = 0
    @ObservationIgnored private var navigationRevision = 0
    @ObservationIgnored private var replacementPending = false
    @ObservationIgnored private var fallbackCount = 0
    @ObservationIgnored private var wantsPlaying = false
    @ObservationIgnored private var preferredVolume: Double = 1
    @ObservationIgnored private var pendingSeek: TimeInterval?
    @ObservationIgnored private var failureReported = false
    @ObservationIgnored private var scriptAvailable = false
    @ObservationIgnored private var lastBoundDocumentID: UUID?

    init(dataStore: WKWebsiteDataStore) {
        let controller = WKUserContentController()
        let handler = PlayerMessageHandler()
        controller.add(handler, contentWorld: .defaultClient, name: "playerBridge")
        let scriptURL = AppIdentity.resourceBundle.url(forResource: "PlayerBridge", withExtension: "js")
        if let scriptURL, let source = try? String(contentsOf: scriptURL, encoding: .utf8) {
            controller.addUserScript(WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .defaultClient
            ))
            self.scriptAvailable = true
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.userContentController = controller
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = true
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.messageHandler = handler
        super.init()
        handler.owner = self
        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
        self.webView.allowsBackForwardNavigationGestures = false
        self.webView.customUserAgent = WebSession.userAgent
    }

    func load(track: Track, occurrence: PlaybackOccurrence, autoplay: Bool = true) {
        guard occurrence.trackID == track.id else {
            self.fail("The selected song no longer matches the playback request.")
            return
        }
        self.track = track
        self.occurrence = occurrence
        self.wantsPlaying = autoplay
        self.pendingSeek = nil
        self.fallbackCount = 0
        self.clock.reset()
        self.navigate()
    }

    func play() {
        self.wantsPlaying = true
        if self.errorMessage != nil {
            self.retry()
        } else {
            self.sendCommand("play")
        }
    }

    func pause() {
        self.wantsPlaying = false
        self.sendCommand("pause")
        self.isPlaying = false
        self.isBuffering = false
        self.onStateChanged?()
    }

    func seek(to position: TimeInterval) {
        guard position.isFinite, position >= 0 else { return }
        self.pendingSeek = position
        if self.gate.documentID != nil {
            self.sendCommand("seek", value: position)
            self.pendingSeek = nil
        }
    }

    func setVolume(_ volume: Double) {
        guard volume.isFinite else { return }
        self.volume = min(1, max(0, volume))
        self.preferredVolume = self.volume
        self.sendCommand("volume", value: self.volume)
    }

    func stop() {
        self.deadline?.cancel()
        self.deadline = nil
        self.wantsPlaying = false
        self.sendCommand("pause")
        self.gate = PlaybackEventGate()
        self.lastBoundDocumentID = nil
        self.track = nil
        self.occurrence = nil
        self.navigation = nil
        self.replacementPending = false
        self.webView.stopLoading()
        self.webView.loadHTMLString("<!doctype html><title>Player</title>", baseURL: nil)
        self.isPlaying = false
        self.isBuffering = false
        self.errorMessage = nil
        self.pendingSeek = nil
        self.clock.reset()
        self.onStateChanged?()
    }

    func retry() {
        guard self.track != nil, self.occurrence != nil else { return }
        self.fallbackCount = 0
        if self.clock.position > 0 { self.pendingSeek = self.clock.position }
        self.navigate()
    }

    private func navigate() {
        guard self.scriptAvailable else {
            self.fail("The player could not load its playback controls. Reinstall the app and try again.")
            return
        }
        guard let track, let occurrence, let url = PlaybackNavigation.watchURL(trackID: track.id) else { return }
        self.deadline?.cancel()
        self.navigation = nil
        self.webView.stopLoading()
        let loadID = UUID()
        self.gate.activate(loadID: loadID, occurrence: occurrence)
        self.commandRevision = 0
        self.navigationRevision += 1
        self.failureReported = false
        self.isPlaying = false
        self.isBuffering = self.wantsPlaying
        self.errorMessage = nil
        if let currentURL = self.webView.url, PlaybackNavigation.permits(currentURL),
           let documentID = self.lastBoundDocumentID {
            self.replaceNavigation(with: url, loadID: loadID, documentID: documentID)
        } else {
            self.replacementPending = false
            self.navigation = self.webView.load(URLRequest(url: url))
        }
        self.deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(18)) } catch { return }
            guard let self, self.gate.loadID == loadID else { return }
            self.retryNavigationOrFail("YouTube Music did not make this song ready. Check your connection or account, then try again.")
        }
        self.onStateChanged?()
    }

    private func replaceNavigation(with url: URL, loadID: UUID, documentID: UUID) {
        self.replacementPending = true
        self.webView.callAsyncJavaScript(
            "return globalThis.YTMusicNativePlayer?.replaceNavigation(request) ?? false;",
            arguments: ["request": ["revision": self.navigationRevision, "targetURL": url.absoluteString,
                                    "documentID": documentID.uuidString.lowercased()]],
            in: nil,
            in: .defaultClient
        ) { [weak self] result in
            guard let self, self.gate.loadID == loadID, self.replacementPending, self.navigation == nil else { return }
            if case let .success(value) = result, value as? Bool == true { return }
            self.replacementPending = false
            self.navigation = self.webView.load(URLRequest(url: url))
        }
    }

    private func bindBridge() {
        guard let loadID = self.gate.loadID, let occurrence else { return }
        let identity = PlaybackBridgeIdentity(occurrence)
        let context: [String: Any] = [
            "loadID": loadID.uuidString,
            "identity": [
                "sessionID": identity.sessionID.uuidString,
                "entryID": identity.entryID.uuidString,
                "trackID": identity.trackID,
                "generation": identity.generation,
            ],
            "autoplay": self.wantsPlaying,
            "volume": self.preferredVolume,
        ]
        self.webView.callAsyncJavaScript(
            "return globalThis.YTMusicNativePlayer?.bind(context) ?? null;",
            arguments: ["context": context],
            in: nil,
            in: .defaultClient
        ) { [weak self] result in
            guard let self, self.gate.loadID == loadID else { return }
            guard case let .success(body) = result,
                  let message = PlaybackBridgeMessage.decode(body),
                  message.loadID == loadID,
                  message.identity == identity
            else {
                self.retryNavigationOrFail("YouTube Music's playback controls did not respond. Try again.")
                return
            }
            self.gate.bind(documentID: message.documentID)
            self.lastBoundDocumentID = message.documentID
            self.receive(message)
            // Play and pause may have changed while the bridge was binding.
            self.sendCommand(self.wantsPlaying ? "play" : "pause")
            self.sendCommand("volume", value: self.preferredVolume)
            if let position = self.pendingSeek {
                self.sendCommand("seek", value: position)
                self.pendingSeek = nil
            }
        }
    }

    private func sendCommand(_ name: String, value: Double? = nil) {
        guard let loadID = self.gate.loadID, self.gate.documentID != nil else { return }
        self.commandRevision += 1
        let revision = self.commandRevision
        var command: [String: Any] = ["loadID": loadID.uuidString, "revision": revision, "name": name]
        if let value { command["value"] = value }
        self.webView.callAsyncJavaScript(
            "return globalThis.YTMusicNativePlayer?.command(command) ?? false;",
            arguments: ["command": command],
            in: nil,
            in: .defaultClient
        ) { [weak self] result in
            guard let self, self.gate.loadID == loadID, self.commandRevision == revision else { return }
            if case .failure = result, !self.failureReported {
                self.fail("The player stopped responding. Try loading the song again.")
            }
        }
    }

    fileprivate func receive(_ scriptMessage: WKScriptMessage) {
        let origin = scriptMessage.frameInfo.securityOrigin
        guard scriptMessage.name == "playerBridge",
              scriptMessage.frameInfo.isMainFrame,
              origin.protocol == "https", origin.host == "music.youtube.com",
              origin.port == 0 || origin.port == 443,
              let message = PlaybackBridgeMessage.decode(scriptMessage.body)
        else { return }
        self.receive(message)
    }

    private func receive(_ message: PlaybackBridgeMessage) {
        guard self.gate.accept(message), !self.failureReported else { return }
        if message.kind == .error {
            let description: String
            switch message.errorCode {
            case "playback_blocked": description = "YouTube Music could not start playback. Check the player or sign in, then try again."
            case "target_changed": description = "The YouTube Music page changed songs. Choose a song using the app's controls to continue."
            default: description = "YouTube Music could not play this song. It may be unavailable for this account or region."
            }
            self.fail(description)
            return
        }
        if message.acceptsPagePause(latestCommandRevision: self.commandRevision) {
            self.wantsPlaying = false
        }
        if !self.wantsPlaying || (message.isPlaying && !message.isBuffering) {
            self.deadline?.cancel()
            self.deadline = nil
        } else if self.deadline == nil, let loadID = self.gate.loadID {
            self.deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(18)) } catch { return }
                guard let self, self.gate.loadID == loadID, self.wantsPlaying else { return }
                if self.clock.position > 0 { self.pendingSeek = self.clock.position }
                self.retryNavigationOrFail("Playback stalled. Check your connection or retry this song.")
            }
        }
        let playing = message.isPlaying && self.wantsPlaying
        let buffering = self.wantsPlaying && (message.isBuffering || (!message.mediaReady && !message.isAd))
        let changed = self.isPlaying != playing || self.isBuffering != buffering
        self.isPlaying = playing
        self.isBuffering = buffering
        self.volume = message.volume
        if !message.isAd, message.mediaReady {
            self.clock.update(position: message.position, duration: message.duration)
        }
        if message.kind == .ended, let occurrence = self.occurrence {
            self.isPlaying = false
            self.isBuffering = false
            self.onStateChanged?()
            self.onEnded?(occurrence)
        } else if changed || message.kind != .progress {
            self.onStateChanged?()
        }
    }

    private func retryNavigationOrFail(_ message: String) {
        guard self.gate.loadID != nil else { return }
        if self.fallbackCount < 1 {
            self.fallbackCount += 1
            self.navigate()
        } else {
            self.fail(message)
        }
    }

    private func fail(_ message: String) {
        guard !self.failureReported else { return }
        self.failureReported = true
        self.deadline?.cancel()
        self.deadline = nil
        self.errorMessage = message
        self.wantsPlaying = false
        self.isPlaying = false
        self.isBuffering = false
        self.sendCommand("pause")
        self.onStateChanged?()
        self.onFailure?()
    }
}

@MainActor
private final class PlayerMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: WebPlayer?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        self.owner?.receive(message)
    }
}

extension WebPlayer: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank", self.gate.loadID == nil {
            decisionHandler(.allow)
        } else {
            guard PlaybackNavigation.permits(url) else { decisionHandler(.cancel); return }
            if navigationAction.targetFrame?.isMainFrame != false,
               let track = self.track,
               let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value,
               target != track.id {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if self.replacementPending, self.gate.loadID != nil, self.navigation == nil {
            self.navigation = navigation
            self.replacementPending = false
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let expected = self.navigation, navigation === expected,
              let url = webView.url, PlaybackNavigation.permits(url)
        else { return }
        self.onPageReady?(webView)
        self.bindBridge()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        self.navigationFailed(navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        self.navigationFailed(navigation, error: error)
    }

    private func navigationFailed(_ navigation: WKNavigation?, error: any Error) {
        guard let expected = self.navigation, navigation === expected,
              (error as NSError).code != NSURLErrorCancelled
        else { return }
        self.retryNavigationOrFail("YouTube Music could not load. Check your connection and try again.")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        self.retryNavigationOrFail("The playback process stopped. Try loading the song again.")
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }
}
