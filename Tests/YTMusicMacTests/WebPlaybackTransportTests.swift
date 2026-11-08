import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

@MainActor @Suite("Injected web transport boundary")
struct WebPlaybackTransportTests {
    @Test func controlsCanBeHeldWithoutConstructingANativePlayerOrGrantingEvents() {
        let engine = ControlledWebPlaybackTransport(), occurrence = webTransportOccurrence()
        let transport: any WebPlaybackTransport = engine
        transport.load(track: webTransportTrack, occurrence: occurrence, autoplay: false)
        transport.play(); transport.setVolume(0)
        #expect(engine.actions == [.load(occurrence, autoplay: false), .play, .volume(0)])
        #expect(transport.playbackIntent && transport.volume == 0 && transport.currentOutputContext == nil)
        #expect(transport.requestedOutputContext?.engineInstanceID == transport.outputInstanceID)
        #expect(transport.clock.duration == 0 && !transport.hasConfirmedPosition)
    }
    @Test func actualSyntheticAcknowledgmentDeliversBindingBeforeEventsOnlyOncePerContext() {
        let engine = ControlledWebPlaybackTransport(); var order: [String] = []
        engine.onOutputBindingReady = { context in
            #expect(engine.currentOutputContext == context)
            order.append("ready")
        }
        engine.onOutputEvent = { event in
            #expect(engine.currentOutputContext == event.context)
            order.append("event")
        }
        engine.load(track: webTransportTrack, occurrence: webTransportOccurrence(), autoplay: true)
        #expect(order.isEmpty)
        engine.acknowledge(); engine.acknowledge(position: 2)
        #expect(order.first == "ready" && order.filter { $0 == "ready" }.count == 1)
        #expect(order.contains("event") && engine.isPlaying && engine.hasConfirmedPosition)
    }
    @Test func commandRetargetRevokesTheOldBindingAndCannotAcknowledgeUntilACommandIsIssued() {
        let engine = ControlledWebPlaybackTransport(); var contexts: [WebPlaybackOutputContext] = []
        engine.onOutputBindingReady = { contexts.append($0) }
        engine.load(track: webTransportTrack, occurrence: webTransportOccurrence(), autoplay: false)
        engine.acknowledge()
        let old = engine.currentOutputContext
        engine.invalidateOutputScopes(.command)
        #expect(engine.currentOutputContext == nil)
        engine.acknowledge()
        #expect(contexts.count == 1 && engine.currentOutputContext == nil)
        engine.play(); engine.acknowledge()
        #expect(contexts.count == 2 && engine.currentOutputContext != old && engine.isPlaying)
    }
    @Test func aReentrantCommandAcknowledgmentCannotRelabelTheOuterLoadEvent() {
        let engine = ControlledWebPlaybackTransport(); var receipts: [WebPlaybackOutputContext] = []
        var events: [WebPlaybackOutputContext] = []
        engine.automaticallyAcknowledgesCommands = true
        engine.onOutputBindingReady = { context in
            receipts.append(context)
            if receipts.count == 1 {
                engine.invalidateOutputScopes(.command)
                engine.play()
            }
        }
        engine.onOutputEvent = { events.append($0.context) }
        engine.load(track: webTransportTrack, occurrence: webTransportOccurrence(), autoplay: false)
        engine.acknowledge()
        #expect(receipts.count == 2 && !events.isEmpty)
        #expect(events.allSatisfy { $0 == receipts.last } && engine.isPlaying)
    }
    @Test func pauseThenPlayAndMuteAreObservableBeforeDelayedReady() {
        let engine = ControlledWebPlaybackTransport()
        engine.load(track: webTransportTrack, occurrence: webTransportOccurrence(), autoplay: true)
        engine.pause(); engine.play(); engine.setVolume(0)
        #expect(engine.actions.suffix(3) == [.pause, .play, .volume(0)])
        #expect(engine.playbackIntent && engine.volume == 0 && engine.currentOutputContext == nil)
        engine.acknowledge()
        #expect(engine.isPlaying && engine.volume == 0)
    }
    @Test func recoveryKeepsTheOldReceiptForAdmissionButNeedsANewLoadAcknowledgment() {
        let engine = ControlledWebPlaybackTransport()
        engine.load(track: webTransportTrack, occurrence: webTransportOccurrence(), autoplay: true)
        engine.acknowledge(position: 30)
        let old = engine.currentOutputContext
        engine.onOutputRecoveryRequested = { context, position in
            #expect(context == old && position == 30)
            return 28
        }
        #expect(engine.requestRecovery(position: 30))
        #expect(engine.currentOutputContext == nil && engine.requestedOutputContext?.loadID != old?.loadID)
        engine.acknowledge(position: 28)
        #expect(engine.currentOutputContext != old && engine.clock.position == 28)
    }
    @Test func informationalFailureNeverAcknowledgesAndRetirementRejectsFutureOperations() async {
        let engine = ControlledWebPlaybackTransport(); var failures = 0, ready = 0
        engine.onOutputBindingReady = { _ in ready += 1 }
        engine.onOutputEvent = { if case .failure = $0.kind { failures += 1 } }
        engine.load(track: webTransportTrack, occurrence: webTransportOccurrence(), autoplay: true)
        engine.failBeforeAcknowledgment()
        #expect(failures == 1 && ready == 0 && engine.currentOutputContext == nil)
        #expect(!engine.isPlaying && !engine.isBuffering && !engine.isStartingPlayback)
        let retirement = engine.revokeOutput(), count = engine.actions.count
        #expect(retirement.ticket.instanceID == engine.outputInstanceID)
        #expect((await retirement.settle()).outcome == .confirmed)
        engine.play(); engine.pause(); engine.seek(to: 10); engine.setVolume(0.4); engine.acknowledge()
        #expect(engine.actions.count == count && engine.requestedOutputContext == nil)
        #expect(engine.revokeOutput() === retirement)
    }
    @Test func heldRetirementHasBoundedBlockedReceiptAndOnlyActualConfirmationMarksQuiet() async {
        let engine = ControlledWebPlaybackTransport(); engine.automaticallyConfirmsRetirement = false
        let operation = engine.revokeOutput()
        engine.timeOutRetirement()
        #expect((await operation.settle()).outcome == .blocked(.timedOut))
        #expect(!operation.isConfirmedQuiet)
        engine.confirmRetirement()
        #expect(operation.isConfirmedQuiet)
        #expect((await operation.settle()).outcome == .blocked(.timedOut))
    }
}
private var webTransportTrack: Track { .init(id: "abcDEF12_-3", title: "Synthetic", artist: "Artist", contentKind: .song) }
private func webTransportOccurrence() -> PlaybackOccurrence {
    .init(sessionID: UUID(), entryID: UUID(), trackID: webTransportTrack.id, generation: 1)
}
