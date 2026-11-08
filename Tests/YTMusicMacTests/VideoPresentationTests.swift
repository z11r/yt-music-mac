import AppKit
import Foundation
import Testing
import WebKit
@testable import YTMusicMac

@MainActor
private final class FixtureVideoWindow: PlayerVideoWindow {
    let contentHost = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    var didClose: (() -> Void)?
    var shown = 0, fullScreenRequests = 0, closed = 0
    func show() { shown += 1 }
    func enterFullScreen() { fullScreenRequests += 1 }
    func close() { closed += 1 }
    func update(pictureInPicture: Bool, pending: Bool, message: String?) {}
}

@MainActor @Suite("Single player video presentation")
struct VideoPresentationTests {
    @Test func oneHostMovesBetweenDestinationsWithoutLoadingOrCloningAWebView() {
        let web = WKWebView(frame: .zero, configuration: configuration())
        let window = FixtureVideoWindow()
        let presentation = VideoPresentationController(makeWindow: { _, _ in window })
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        var external = false
        presentation.bind(view: { web }, hasSelection: { true }, execute: { _ in .unsupported }, visibilityChanged: { external = $0 })
        presentation.attachInline(anchor, visible: false)
        let host = presentation.host
        #expect(host.superview === anchor && web.superview === host && web.isHidden)
        presentation.showWindow(fullScreen: true)
        #expect(presentation.host === host && host.superview === window.contentHost)
        #expect(web.superview === host && !web.isHidden && external)
        #expect(window.shown == 1 && window.fullScreenRequests == 1)
        presentation.attachInline(anchor, visible: false)
        #expect(host.superview === window.contentHost && !web.isHidden)
        var returned = false
        presentation.didReturnToMain = { returned = true }
        presentation.returnToMain()
        #expect(returned && !presentation.isWindowPresented && window.closed == 1)
        #expect(host.superview === anchor && web.superview === host)
        #expect(!web.isHidden && !external && web.url == nil && !web.isLoading)
    }

    @Test func closingAndReplacingTheViewCannotLeaveAnOldHostOrPresentation() {
        var web = WKWebView(frame: .zero, configuration: configuration())
        let old = web
        let window = FixtureVideoWindow()
        let presentation = VideoPresentationController(makeWindow: { _, _ in window })
        let anchor = NSView()
        var cleanups = 0
        presentation.bind(view: { web }, hasSelection: { true }, execute: { _ in .unsupported },
                          visibilityChanged: { _ in }, closeMedia: { cleanups += 1 })
        presentation.attachInline(anchor, visible: false); presentation.showWindow()
        web = WKWebView(frame: .zero, configuration: configuration())
        presentation.webViewChanged()
        #expect(old.superview == nil && presentation.host.subviews.count == 1)
        #expect(web.superview === presentation.host && presentation.host.superview === window.contentHost)
        window.didClose?()
        #expect(!presentation.isWindowPresented && cleanups == 1)
        #expect(presentation.host.superview === anchor && web.isHidden)
    }

    @Test func aFullscreenPlaceholderFinishesRetiringBeforeTheHostInstallsANewView() throws {
        var web = WKWebView(frame: .zero, configuration: configuration())
        let previous = web
        let presentation = VideoPresentationController()
        presentation.bind(view: { web }, hasSelection: { true }, execute: { _ in .unsupported }, visibilityChanged: { _ in })
        let anchor = NSView(); presentation.attachInline(anchor, visible: true)
        var completion: (@MainActor () -> Void)?
        // A fixture supplies the pending media-close callback. No window or
        // actual WebKit presentation is requested by this test.
        presentation.retireWebView(previous, needsMediaClose: true) { completion = $0 }
        web = WKWebView(frame: .zero, configuration: configuration())
        presentation.webViewChanged(); presentation.attachInline(anchor, visible: true)
        #expect(previous.superview === presentation.host && web.superview == nil)
        let finish = try #require(completion)
        finish()
        #expect(previous.superview == nil && web.superview === presentation.host)
        #expect(presentation.host.subviews.count == 1)
    }

    @Test func unsupportedOrMissingSelectionNeverCreatesAWindowOrExecutesAPresentation() async {
        let web = WKWebView(frame: .zero, configuration: configuration())
        var creations = 0, executions = 0
        let presentation = VideoPresentationController(makeWindow: { _, _ in creations += 1; return FixtureVideoWindow() })
        presentation.bind(view: { web }, hasSelection: { false }, execute: { _ in executions += 1; return .rejected },
                          visibilityChanged: { _ in })
        presentation.showWindow(); presentation.togglePictureInPicture()
        await Task.yield()
        #expect(creations == 0 && executions == 0 && presentation.message != nil)
        #expect(web.url == nil && !web.isLoading)
    }

    @Test func closingFencesALateOptionalResultAndReleasesVisibility() async throws {
        let web = WKWebView(frame: .zero, configuration: configuration())
        let presentation = VideoPresentationController()
        var continuation: CheckedContinuation<VideoPresentationResult, Never>?
        var external = false
        presentation.bind(view: { web }, hasSelection: { true }, execute: { _ in
            await withCheckedContinuation { continuation = $0 }
        }, visibilityChanged: { external = $0 })
        presentation.accept(.init(hasVideo: true, supportsPictureInPicture: true))
        presentation.togglePictureInPicture()
        for _ in 0..<20 where continuation == nil { await Task.yield() }
        let finish = try #require(continuation)
        #expect(presentation.isRequestPending && external)
        presentation.close()
        finish.resume(returning: .confirmed(active: true))
        await Task.yield()
        #expect(!presentation.isRequestPending && !presentation.capabilities.isPictureInPictureActive && !external)
        #expect(presentation.message == nil)
    }

    @Test func optionalReplyCompletesOnceAndHasABoundedTimeout() async {
        let first = VideoPresentationReply()
        let result = await first.wait { finish in finish(.confirmed(active: true)); finish(.rejected) }
        #expect(result == .confirmed(active: true))
        let timeout = VideoPresentationReply()
        #expect(await timeout.wait(timeout: .milliseconds(1), start: { _ in }) == .rejected)
        let cancelled = VideoPresentationReply(); cancelled.finish(.cancelled)
        var started = false
        #expect(await cancelled.wait(start: { _ in started = true }) == .cancelled)
        #expect(!started)
    }

    @Test func malformedCapabilitiesAreConservativeAndCannotGrantPresentation() throws {
        let data = Data(#"{"hasVideo":true,"supportsPictureInPicture":"yes","isPictureInPictureActive":7}"#.utf8)
        let value = try JSONDecoder().decode(VideoPresentationSnapshot.self, from: data)
        #expect(value.hasVideo && !value.supportsPictureInPicture && !value.isPictureInPictureActive)
    }

    private func configuration() -> WKWebViewConfiguration {
        let value = WKWebViewConfiguration(); value.websiteDataStore = .nonPersistent(); return value
    }
}
