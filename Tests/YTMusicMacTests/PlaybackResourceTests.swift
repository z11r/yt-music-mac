import Foundation
import Observation
import Testing
import WebKit
@testable import YTMusicMac

@MainActor
private final class ChangeFlag {
    var changed = false
}

@MainActor
private func observeDisplay(of clock: PlaybackClock) -> ChangeFlag {
    let flag = ChangeFlag()
    withObservationTracking {
        _ = clock.elapsedSeconds
        _ = clock.duration
        _ = clock.isPastRestartThreshold
    } onChange: {
        MainActor.assumeIsolated { flag.changed = true }
    }
    return flag
}

@MainActor
@Suite("Playback resource use")
struct PlaybackResourceTests {
    @Test func progressWithinTheSameSecondDoesNotRedrawViews() {
        let clock = PlaybackClock()
        clock.update(position: 10.2, duration: 180)
        let sameSecond = observeDisplay(of: clock)
        clock.update(position: 10.9, duration: 180)
        #expect(!sameSecond.changed)
        #expect(clock.position == 10.9)
        let nextSecond = observeDisplay(of: clock)
        clock.update(position: 11.1, duration: 180)
        #expect(nextSecond.changed)
        #expect(clock.elapsedSeconds == 11)
    }

    @Test func restartThresholdChangesOnlyWhenCrossed() {
        let clock = PlaybackClock()
        clock.update(position: 2.9, duration: 180)
        #expect(!clock.isPastRestartThreshold)
        clock.update(position: 3.1, duration: 180)
        #expect(clock.isPastRestartThreshold)
        let later = observeDisplay(of: clock)
        clock.update(position: 3.4, duration: 180)
        #expect(!later.changed)
        clock.reset()
        #expect(!clock.isPastRestartThreshold && clock.elapsedSeconds == 0 && clock.position == 0)
    }

    @Test func invalidPositionsDisplayAsZero() {
        let clock = PlaybackClock()
        clock.update(position: .nan, duration: -.infinity)
        #expect(clock.position == 0 && clock.duration == 0 && clock.elapsedSeconds == 0)
    }

    @Test func stoppingReplacesTheWebViewSoItsPageProcessCanEnd() {
        let player = WebPlayer(dataStore: .nonPersistent())
        let original = player.webView
        let generation = player.webViewGeneration
        player.stop()
        #expect(player.webView !== original)
        #expect(player.webViewGeneration == generation + 1)
        #expect(original.navigationDelegate == nil && original.uiDelegate == nil)
        #expect(player.webView.navigationDelegate === player)
        #expect(player.webView.url == nil)
        #expect(player.isPageUnloaded)
    }

    @Test func aReplacementWebViewKeepsThePlaybackBridge() {
        let player = WebPlayer(dataStore: .nonPersistent())
        let scripts = player.webView.configuration.userContentController.userScripts.count
        player.stop()
        #expect(scripts == 1)
        #expect(player.webView.configuration.userContentController.userScripts.count == scripts)
        #expect(player.webView.customUserAgent == WebSession.userAgent)
    }

    @Test func showingThePanelWithoutASongDoesNotLoadAPage() {
        let player = WebPlayer(dataStore: .nonPersistent())
        let original = player.webView
        player.isPresented = true
        player.isPresented = false
        #expect(player.webView === original)
        #expect(player.webView.url == nil && !player.webView.isLoading)
        #expect(player.isPageUnloaded)
    }
}
