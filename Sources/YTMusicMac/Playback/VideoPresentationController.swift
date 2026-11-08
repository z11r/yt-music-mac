import AppKit
import Observation
import WebKit

@MainActor
protocol PlayerVideoWindow: AnyObject {
    var contentHost: NSView { get }
    var didClose: (() -> Void)? { get set }
    func show()
    func enterFullScreen()
    func close()
    func update(pictureInPicture: Bool, pending: Bool, message: String?)
}

/// Owns one host. The embedded view and video window are destinations for that
/// host, never competing representables that each claim the playback web view.
@MainActor @Observable
final class VideoPresentationController {
    private(set) var isWindowPresented = false
    private(set) var capabilities = VideoPresentationSnapshot()
    private(set) var isRequestPending = false
    private(set) var message: String?
    @ObservationIgnored let host = WebViewHost()
    @ObservationIgnored var didReturnToMain: () -> Void = {}
    @ObservationIgnored private var observationID = UUID()
    @ObservationIgnored private var retirementID: UUID?
    @ObservationIgnored private var outputRetired = false
    @ObservationIgnored private weak var inlineAnchor: NSView?
    @ObservationIgnored private var window: (any PlayerVideoWindow)?
    @ObservationIgnored private var viewProvider: () -> WKWebView? = { nil }
    @ObservationIgnored private var hasSelection: () -> Bool = { false }
    @ObservationIgnored private var execute: (Bool) async -> VideoPresentationResult = { _ in .unsupported }
    @ObservationIgnored private var closeMedia: () -> Void = {}
    @ObservationIgnored private var visibilityChanged: (Bool) -> Void = { _ in }
    @ObservationIgnored private let makeWindow: (@escaping () -> Void, @escaping () -> Void) -> any PlayerVideoWindow
    @ObservationIgnored private var inlineVisible = false
    @ObservationIgnored private var startingPlayback = false
    @ObservationIgnored private var elementFullscreen = false
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()

    init(makeWindow: @escaping (@escaping () -> Void, @escaping () -> Void) -> any PlayerVideoWindow = {
        NativePlayerVideoWindow(returnToMain: $0, pictureInPicture: $1)
    }) { self.makeWindow = makeWindow }

    var canRequestPictureInPicture: Bool {
        !outputRetired && !isRequestPending && (capabilities.isPictureInPictureActive ||
            (capabilities.hasVideo && capabilities.supportsPictureInPicture))
    }

    func bind(view: @escaping () -> WKWebView?, hasSelection: @escaping () -> Bool,
              execute: @escaping (Bool) async -> VideoPresentationResult,
              visibilityChanged: @escaping (Bool) -> Void, closeMedia: @escaping () -> Void = {}) {
        viewProvider = view; self.hasSelection = hasSelection
        self.execute = execute; self.visibilityChanged = visibilityChanged; self.closeMedia = closeMedia
        webViewChanged()
    }

    func attachInline(_ anchor: NSView, visible: Bool) {
        inlineAnchor = anchor; inlineVisible = visible
        placeHost(); refreshVisibility()
    }

    func detachInline(_ anchor: NSView) {
        guard inlineAnchor === anchor else { return }
        inlineAnchor = nil
        if !outputRetired && !isWindowPresented { host.removeFromSuperview() }
        refreshVisibility()
    }

    func setInlineVisible(_ value: Bool) { inlineVisible = value; refreshVisibility() }
    func setStartingPlayback(_ value: Bool) { startingPlayback = value; refreshVisibility() }

    func webViewChanged() {
        guard !outputRetired else { return }
        invalidate()
        if retirementID != nil { return }
        observationID = UUID()
        let observedID = observationID
        observation?.invalidate(); observation = nil
        if let view = viewProvider() {
            elementFullscreen = view.fullscreenState != .notInFullscreen
            observation = view.observe(\.fullscreenState, options: [.new]) { [weak self] _, change in
                let active = change.newValue != .notInFullscreen
                Task { @MainActor [weak self] in
                    guard let self, self.observationID == observedID else { return }
                    self.elementFullscreen = active
                    self.placeHost(); self.refreshVisibility()
                }
            }
        } else { elementFullscreen = false }
        refreshVisibility()
    }

    /// WebKit restores the original view through its fullscreen placeholder.
    /// Wait for that restoration before installing a replacement in the host.
    func retireWebView(_ previous: WKWebView, needsMediaClose: Bool,
                       close: (@escaping @MainActor () -> Void) -> Void) {
        guard needsMediaClose else { close({}); return }
        let id = UUID(); retirementID = id
        observationID = UUID(); observation?.invalidate(); observation = nil
        invalidate()
        close { [weak self, previous] in
            if let before = previous.previousKeyView, before.nextKeyView === previous {
                let after = previous.nextKeyView
                before.nextKeyView = after.map { $0.isDescendant(of: previous) } ?? true ? nil : after
            }
            previous.nextKeyView = nil
            previous.removeFromSuperview()
            guard let self, self.retirementID == id else { return }
            self.retirementID = nil; self.elementFullscreen = false
            self.webViewChanged(); self.placeHost(); self.refreshVisibility()
        }
    }

    func accept(_ snapshot: VideoPresentationSnapshot) {
        guard !outputRetired else { return }
        if capabilities != snapshot { capabilities = snapshot }
        refreshVisibility()
    }

    func clearMessage() { message = nil; refreshVisibility() }

    func invalidate() {
        requestID = UUID(); request?.cancel(); request = nil
        isRequestPending = false; capabilities = .init(); message = nil
        refreshVisibility()
    }

    func showWindow(fullScreen: Bool = false) {
        guard !outputRetired else { return }
        guard hasSelection(), viewProvider() != nil else { message = AppLocalization.text("Choose a song or video first."); return }
        guard !elementFullscreen else {
            message = AppLocalization.text("Exit the current full-screen presentation before moving the player.")
            return
        }
        if window == nil {
            let newWindow = makeWindow({ [weak self] in self?.returnToMain() }, { [weak self] in self?.togglePictureInPicture() })
            newWindow.didClose = { [weak self] in self?.windowClosed() }
            window = newWindow; isWindowPresented = true
        }
        message = nil
        placeHost(); refreshVisibility()
        window?.show()
        if fullScreen { window?.enterFullScreen() }
    }

    func returnToMain() {
        guard !outputRetired else { return }
        // Element fullscreen belongs to WebKit until it restores its placeholder.
        guard !elementFullscreen else {
            message = AppLocalization.text("Exit the current full-screen presentation before moving the player.")
            refreshVisibility(); return
        }
        invalidate(); closeMedia()
        let previous = window
        window = nil; isWindowPresented = false
        previous?.didClose = nil; previous?.close()
        inlineVisible = true; didReturnToMain()
        placeHost(); refreshVisibility()
    }

    /// Revoke controls now; keep WebKit's placeholder untouched until its exact close acknowledgment.
    func revokeOutputForRetirement() {
        outputRetired = true; observationID = UUID()
        observation?.invalidate(); observation = nil
        invalidate()
    }
    func completeOutputRetirement() {
        guard outputRetired else { return }
        retirementID = nil; elementFullscreen = false
        let previous = window; window = nil; isWindowPresented = false
        previous?.didClose = nil; previous?.close()
        host.show(nil, hidden: true); host.removeFromSuperview()
        visibilityChanged(false)
    }

    func close() {
        guard !outputRetired else { return }
        invalidate(); closeMedia()
        let previous = window
        window = nil; isWindowPresented = false
        previous?.didClose = nil; previous?.close()
        placeHost(); refreshVisibility()
    }

    func togglePictureInPicture() {
        guard canRequestPictureInPicture else {
            message = AppLocalization.text("Picture in Picture is unavailable for this recording.")
            refreshVisibility(); return
        }
        request?.cancel()
        let id = UUID(); requestID = id
        let active = !capabilities.isPictureInPictureActive
        isRequestPending = true; message = nil; refreshVisibility()
        request = Task { [weak self, execute] in
            let result = await execute(active)
            guard let self, self.requestID == id, !Task.isCancelled else { return }
            self.request = nil; self.isRequestPending = false
            switch result {
            case let .confirmed(value): self.capabilities.isPictureInPictureActive = value
            case .unsupported: self.message = AppLocalization.text("Picture in Picture is unavailable for this recording.")
            case .rejected: self.message = AppLocalization.text("Picture in Picture could not open. Try the video window or the web player's controls.")
            case .stale, .cancelled: break
            }
            self.refreshVisibility()
        }
    }

    private func windowClosed() {
        if outputRetired { window = nil; isWindowPresented = false; return }
        invalidate(); closeMedia()
        window = nil; isWindowPresented = false
        placeHost(); refreshVisibility()
    }

    private func placeHost() {
        guard !outputRetired, !elementFullscreen, retirementID == nil else { return }
        let destination = window?.contentHost ?? inlineAnchor
        if let destination, host.superview !== destination {
            host.removeFromSuperview(); host.frame = destination.bounds
            host.autoresizingMask = [.width, .height]; destination.addSubview(host)
        } else if destination == nil { host.removeFromSuperview() }
    }

    private func refreshVisibility() {
        guard !outputRetired else { visibilityChanged(false); return }
        let external = isWindowPresented || capabilities.isPictureInPictureActive || isRequestPending || elementFullscreen || retirementID != nil
        visibilityChanged(external)
        let hidden = !isWindowPresented && !inlineVisible && !startingPlayback && !capabilities.isPictureInPictureActive && !isRequestPending
        if retirementID == nil { host.show(viewProvider(), hidden: hidden) }
        window?.update(pictureInPicture: capabilities.isPictureInPictureActive, pending: isRequestPending, message: message)
    }
}

@MainActor
private final class NativePlayerVideoWindow: NSObject, PlayerVideoWindow, NSWindowDelegate, NSToolbarDelegate {
    let contentHost = NSView()
    private let window: NSWindow
    private let returnToMain: () -> Void
    private let pictureInPicture: () -> Void
    var didClose: (() -> Void)?
    private weak var pipItem: NSToolbarItem?
    private static let returnID = NSToolbarItem.Identifier("player.return-main")
    private static let pipID = NSToolbarItem.Identifier("player.picture-in-picture")

    init(returnToMain: @escaping () -> Void, pictureInPicture: @escaping () -> Void) {
        self.returnToMain = returnToMain; self.pictureInPicture = pictureInPicture
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        super.init()
        window.title = AppLocalization.text("Video Player")
        window.contentView = contentHost
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let toolbar = NSToolbar(identifier: "player.video-toolbar")
        toolbar.delegate = self; window.toolbar = toolbar
        window.collectionBehavior.insert(.fullScreenPrimary)
    }
    func show() { window.makeKeyAndOrderFront(nil) }
    func enterFullScreen() { if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } }
    func close() { window.close() }
    func update(pictureInPicture: Bool, pending: Bool, message: String?) {
        window.subtitle = message ?? ""
        pipItem?.label = pictureInPicture ? AppLocalization.text("Exit Picture in Picture") : AppLocalization.text("Picture in Picture")
        pipItem?.isEnabled = !pending
    }
    func windowWillClose(_ notification: Notification) { didClose?() }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.returnID, Self.pipID, .flexibleSpace] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.returnID, .flexibleSpace, Self.pipID] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.target = self
        if identifier == Self.returnID {
            item.label = AppLocalization.text("Return to Main Window")
            item.image = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: nil)
            item.action = #selector(returnAction)
        } else if identifier == Self.pipID {
            item.label = AppLocalization.text("Picture in Picture")
            item.image = NSImage(systemSymbolName: "pip", accessibilityDescription: nil)
            item.action = #selector(pipAction); pipItem = item
        } else { return nil }
        item.toolTip = item.label
        return item
    }
    @objc private func returnAction() { returnToMain() }
    @objc private func pipAction() { pictureInPicture() }
}
