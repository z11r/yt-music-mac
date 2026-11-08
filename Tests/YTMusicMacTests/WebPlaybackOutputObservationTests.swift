import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

@Suite("Acknowledged native web output contexts")
struct WebPlaybackOutputObservationTests {
    @Test func requestedLoadDoesNotCreateOutputAuthorityBeforeAcknowledgment() throws {
        let f = WebObservationFixture()
        #expect(f.observation.requested == f.context && f.observation.current == nil)
        #expect(!f.observation.accepts(f.context))
        let receipt = try #require(try f.accept())
        #expect(receipt.context == f.context && receipt.needsBinding && receipt.acknowledgedCommandRevision == 0)
        #expect(f.observation.accepts(f.context))
    }
    @Test func oneReadyReceiptPerContextSurvivesVolumeAndProgressRevisionUpdates() throws {
        let f = WebObservationFixture()
        #expect(try #require(try f.accept()).needsBinding)
        for sequence in 2...20 {
            let receipt = try #require(try f.accept(sequence: sequence, revision: sequence, kind: sequence % 2 == 0 ? "state" : "progress"))
            #expect(!receipt.needsBinding && receipt.context == f.context)
        }
    }
    @Test func retargetImmediatelyRevokesOldCallbacksAndWaitsForActualCommandAcknowledgment() throws {
        let f = WebObservationFixture(); _ = try #require(try f.accept())
        let old = f.context
        let next = WebPlaybackOutputContext(engineInstanceID: old.engineInstanceID, loadID: old.loadID, occurrence: old.occurrence,
            commandEpoch: UUID(), minimumCommandRevision: 7)
        f.observation.prepare(next)
        #expect(f.observation.current == nil && !f.observation.accepts(old))
        #expect(try f.accept(sequence: 2, revision: 6) == nil)
        // An old ended callback must not consume the new intent's end gate.
        #expect(try f.accept(sequence: 3, revision: 6, kind: "ended") == nil)
        let receipt = try #require(try f.accept(sequence: 4, revision: 7, kind: "progress"))
        #expect(receipt.needsBinding && receipt.context == next && !f.observation.accepts(old))
        #expect(try #require(try f.accept(sequence: 5, revision: 8, kind: "ended")).context == next)
    }
    @Test func pendingDocumentCannotAcknowledgeANewIntentBeforeTheNativeCommandIsSent() throws {
        let f = WebObservationFixture(bound: false)
        let context = WebPlaybackOutputContext(engineInstanceID: f.context.engineInstanceID, loadID: f.context.loadID,
            occurrence: f.context.occurrence, commandEpoch: UUID(), minimumCommandRevision: 1)
        f.observation.prepare(context)
        #expect(try f.accept() == nil)
        f.gate.bind(documentID: f.document)
        #expect(try f.accept(revision: 0) == nil)
        #expect(f.observation.current == nil)
        #expect(try f.accept(revision: 1, issueCommand: false) == nil)
        #expect(try #require(try f.accept(revision: 2)).context == context)
    }
    @Test func recoveryChangesTheLoadAndRequiresAFreshAcknowledgmentForTheSameOccurrence() throws {
        let f = WebObservationFixture(); _ = try #require(try f.accept())
        let old = f.context
        let recovery = WebPlaybackOutputContext(engineInstanceID: old.engineInstanceID, loadID: UUID(), occurrence: old.occurrence,
            commandEpoch: UUID(), minimumCommandRevision: 0)
        f.observation.prepare(recovery)
        f.gate.activate(loadID: recovery.loadID, occurrence: recovery.occurrence)
        f.gate.bind(documentID: f.document)
        #expect(!f.observation.accepts(old) && f.observation.current == nil)
        #expect(try f.accept(sequence: 2) == nil)
        let receipt = try #require(try f.accept(sourceContext: recovery))
        #expect(receipt.needsBinding && receipt.context == recovery && f.observation.accepts(recovery))
    }
    @Test func wrongLoadOccurrenceDocumentSequenceAndMediaCannotBindOrConsumeEvents() throws {
        let f = WebObservationFixture()
        let first = try #require(try f.accept(sequence: 2, media: 3))
        let otherOccurrence = PlaybackOccurrence(sessionID: UUID(), entryID: UUID(), trackID: "abcDEF12_-3", generation: 1)
        let wrongOccurrence = WebPlaybackOutputContext(engineInstanceID: f.context.engineInstanceID, loadID: f.context.loadID,
            occurrence: otherOccurrence, commandEpoch: f.context.commandEpoch, minimumCommandRevision: 0)
        #expect(try f.accept(sequence: 3, sourceContext: wrongOccurrence) == nil)
        #expect(try f.accept(sequence: 3, document: UUID()) == nil)
        #expect(try f.accept(sequence: 2, media: 3) == nil)
        #expect(try f.accept(sequence: 3, media: 2) == nil)
        #expect(f.observation.current == first.context)
        #expect(try #require(try f.accept(sequence: 3, media: 3)).context == first.context)
    }
    @Test func revokeAndFreshEngineCannotReviveCapturedOldContext() throws {
        let f = WebObservationFixture(); _ = try #require(try f.accept())
        let old = f.context
        f.observation.revoke()
        #expect(f.observation.requested == nil && f.observation.current == nil)
        #expect(try f.accept(sequence: 2) == nil && !f.observation.matchesRequest(old))
        let next = WebPlaybackOutputContext(engineInstanceID: UUID(), loadID: UUID(), occurrence: old.occurrence,
            commandEpoch: UUID(), minimumCommandRevision: 0)
        f.observation.prepare(next); f.gate.activate(loadID: next.loadID, occurrence: next.occurrence); f.gate.bind(documentID: f.document)
        #expect(try f.accept(sequence: 3) == nil)
        #expect(try #require(try f.accept(sourceContext: next)).context == next)
        #expect(!f.observation.accepts(old))
    }
    @Test func preAcknowledgmentFailureIsInformationalAndNeverGrantsBinding() {
        let f = WebObservationFixture()
        let failure = WebPlaybackOutputEvent(context: f.context, kind: .failure(message: "Synthetic failure", reason: .navigationFailed))
        #expect(f.observation.matchesRequest(failure.context) && !f.observation.accepts(failure.context))
        f.observation.revoke()
        #expect(!f.observation.matchesRequest(failure.context) && f.observation.current == nil)
    }
    @Test func capturedEventsStayBoundToTheirOriginalContextAfterReentrantNewLoad() throws {
        let f = WebObservationFixture(); let receipt = try #require(try f.accept())
        let progress = WebPlaybackOutputEvent(context: receipt.context, kind: .progress(position: 12, duration: 180, ended: false))
        let next = WebPlaybackOutputContext(engineInstanceID: f.context.engineInstanceID, loadID: UUID(), occurrence: f.context.occurrence,
            commandEpoch: UUID(), minimumCommandRevision: 0)
        f.observation.prepare(next)
        #expect(progress.context == receipt.context && !f.observation.accepts(progress.context))
        #expect(!f.observation.matchesRequest(progress.context))
    }
    @Test func negativeRevisionCannotCreateARequestedOrAcknowledgedContext() throws {
        let f = WebObservationFixture()
        let invalid = WebPlaybackOutputContext(engineInstanceID: f.context.engineInstanceID, loadID: f.context.loadID,
            occurrence: f.context.occurrence, commandEpoch: UUID(), minimumCommandRevision: -1)
        f.observation.prepare(invalid)
        let result = try f.accept()
        #expect(f.observation.requested == nil && f.observation.current == nil && result == nil)
    }
}
private final class WebObservationFixture {
    let context: WebPlaybackOutputContext
    let document = UUID()
    var gate = PlaybackEventGate()
    var observation = WebPlaybackOutputObservation()
    init(bound: Bool = true) {
        context = .init(engineInstanceID: UUID(), loadID: UUID(),
            occurrence: .init(sessionID: UUID(), entryID: UUID(), trackID: "abcDEF12_-3", generation: 1),
            commandEpoch: UUID(), minimumCommandRevision: 0)
        observation.prepare(context); gate.activate(loadID: context.loadID, occurrence: context.occurrence)
        if bound { gate.bind(documentID: document) }
    }
    func accept(sequence: Int = 1, revision: Int = 0, kind: String = "state", media: Int = 1, document: UUID? = nil, sourceContext: WebPlaybackOutputContext? = nil, issueCommand: Bool = true) throws -> WebPlaybackOutputObservation.Receipt? {
        if issueCommand { observation.commandIssued(revision) }
        let message = try webObservationMessage(context: sourceContext ?? context, document: document ?? self.document, sequence: sequence, revision: revision, kind: kind, media: media)
        return observation.accept(message, gate: &gate)
    }
}
private func webObservationMessage(context: WebPlaybackOutputContext, document: UUID, sequence: Int = 1,
                                   revision: Int = 0, kind: String = "state", media: Int = 1) throws -> PlaybackBridgeMessage {
    try #require(PlaybackBridgeMessage.decode([
        "kind": kind, "loadID": context.loadID.uuidString, "documentID": document.uuidString,
        "identity": ["sessionID": context.occurrence.sessionID.uuidString, "entryID": context.occurrence.entryID.uuidString,
                     "trackID": context.occurrence.trackID, "generation": String(context.occurrence.generation)],
        "mediaGeneration": media, "sequence": sequence, "commandRevision": revision,
        "playbackIntent": true, "intentSource": "native", "videoID": context.occurrence.trackID,
        "position": 12, "duration": 180, "volume": 0.7, "isPlaying": true, "isBuffering": false, "isAd": false, "mediaReady": true
    ]))
}
