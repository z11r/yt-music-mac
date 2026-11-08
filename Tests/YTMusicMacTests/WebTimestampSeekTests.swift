import Foundation
import MusicCore
import Observation
import Testing
@testable import YTMusicMac

@MainActor @Suite("Guarded timestamp admission and receipts")
struct WebTimestampSeekTests {
    @Test func oneSynchronousRetargetPrecedesDispatchAndKeepsTheActualSlotUntilCompletion() throws {
        let old = timestampIdentity(), request = WebTimestampSeekRequest(identity: old, position: 30)
        let admission = WebTimestampSeekAdmission(), first = WebTimestampSeekTransaction(admission: admission)
        let replacement = WebTimestampSeekTransaction(admission: admission)
        var calls: [String] = [], results: [WebTimestampSeekOutcome] = []
        var native: (@MainActor (WebTimestampSeekOutcome) -> Void)?
        first.perform(request, current: { old }, retarget: { calls.append("retarget"); return nextTimestampContext(old) }, dispatch: { _, _, callback in
            calls.append("dispatch"); native = callback
        }, completion: { results.append($0) })
        #expect(calls == ["retarget", "dispatch"] && first.isBusy)
        replacement.perform(.init(identity: old, position: 45), current: { old }, retarget: { Issue.record("busy retarget"); return nil },
            dispatch: { _, _, _ in Issue.record("busy dispatch") }, completion: { #expect($0 == .rejected) })
        #expect(results.isEmpty && replacement.isBusy)
        let callback = try #require(native)
        callback(.confirmed(30)); callback(.rejected)
        #expect(results == [.confirmed(30)] && !first.isBusy && !replacement.isBusy)
    }
    @Test func aDuplicateOldNativeCallbackCannotReleaseANewerCallEvenWithTheSameRequestID() throws {
        let old = timestampIdentity(), transaction = WebTimestampSeekTransaction(admission: WebTimestampSeekAdmission())
        let request = WebTimestampSeekRequest(identity: old, position: 20)
        var callbacks: [@MainActor (WebTimestampSeekOutcome) -> Void] = [], count = 0
        for _ in 0..<2 {
            transaction.perform(request, current: { old }, retarget: { nextTimestampContext(old) },
                dispatch: { _, _, callback in callbacks.append(callback) }, completion: { _ in count += 1 })
            if callbacks.count == 1 { callbacks[0](.confirmed(20)) }
        }
        #expect(callbacks.count == 2 && transaction.isBusy && count == 1)
        callbacks[0](.unconfirmed)
        #expect(transaction.isBusy && count == 1)
        callbacks[1](.confirmed(20)); #expect(!transaction.isBusy && count == 2)
    }
    @Test func sharedBusyReleaseIsObservedWithoutReadingAnyPlaybackClock() {
        let admission = WebTimestampSeekAdmission(), transaction = WebTimestampSeekTransaction(admission: admission)
        let old = timestampIdentity(); var completion: (@MainActor (WebTimestampSeekOutcome) -> Void)?
        transaction.perform(.init(identity: old, position: 20), current: { old }, retarget: { nextTimestampContext(old) },
            dispatch: { _, _, callback in completion = callback }, completion: { _ in })
        let changed = TimestampObservationFlag()
        withObservationTracking { #expect(transaction.isBusy) } onChange: { changed.mark() }
        completion?(.unconfirmed)
        #expect(changed.value && !transaction.isBusy)
    }
    @Test func staleInvalidAndCanceledProofNeverRetargetsOrDispatches() async {
        let old = timestampIdentity()
        for request in [WebTimestampSeekRequest(identity: old, position: -1), .init(identity: old, position: 180), .init(identity: old, position: .infinity)] {
            let transaction = WebTimestampSeekTransaction(admission: WebTimestampSeekAdmission())
            transaction.perform(request, current: { old }, retarget: { Issue.record("invalid retarget"); return nil },
                dispatch: { _, _, _ in Issue.record("invalid dispatch") }, completion: { #expect($0 == .rejected) })
            #expect(!transaction.isBusy)
        }
        let transaction = WebTimestampSeekTransaction(admission: WebTimestampSeekAdmission())
        transaction.perform(.init(identity: old, position: 20), current: { nil }, retarget: { Issue.record("stale retarget"); return nil },
            dispatch: { _, _, _ in Issue.record("stale dispatch") }, completion: { #expect($0 == .rejected) })
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            transaction.perform(.init(identity: old, position: 20), current: { old }, retarget: { Issue.record("cancelled retarget"); return nil },
                dispatch: { _, _, _ in Issue.record("cancelled dispatch") }, completion: { #expect($0 == .rejected) })
        }
        await task.value
        #expect(!transaction.isBusy)
    }
    @Test func replacedOrMissingNewEngineEpochLoadOccurrenceAndRevisionNeverDispatch() {
        let old = timestampIdentity()
        for index in 0..<5 {
            let transaction = WebTimestampSeekTransaction(admission: WebTimestampSeekAdmission())
            let context = WebPlaybackOutputContext(engineInstanceID: index == 0 ? UUID() : old.context.engineInstanceID,
                loadID: index == 1 ? UUID() : old.context.loadID,
                occurrence: index == 2 ? .init(sessionID: UUID(), entryID: UUID(), trackID: "other", generation: 2) : old.context.occurrence,
                commandEpoch: index == 3 ? old.context.commandEpoch : UUID(), minimumCommandRevision: index == 4 ? 100 : old.commandRevision + 1)
            transaction.perform(.init(identity: old, position: 20), current: { old }, retarget: { context },
                dispatch: { _, _, _ in Issue.record("invalid binding dispatch") }, completion: { #expect($0 == .rejected) })
            #expect(!transaction.isBusy)
        }
    }
    @Test func timeoutAndCanceledUIReceiptDoNotReleaseTheNativeOperationOrAdmitARetry() async {
        for canceled in [false, true] {
            let old = timestampIdentity(), transaction = WebTimestampSeekTransaction(admission: WebTimestampSeekAdmission())
            let request = WebTimestampSeekRequest(identity: old, position: 20), reply = WebTimestampSeekReply()
            var native: (@MainActor (WebTimestampSeekOutcome) -> Void)?
            transaction.perform(request, current: { old }, retarget: { nextTimestampContext(old) }, dispatch: { _, _, callback in native = callback }, completion: { reply.finish($0) })
            if canceled { reply.finish(.cancelled) }
            let value = await reply.wait(sleep: {}, start: { _ in })
            #expect(value == (canceled ? .cancelled : .unconfirmed))
            #expect(transaction.isBusy)
            native?(.confirmed(20))
            #expect(!transaction.isBusy)
            #expect(await reply.wait(start: { _ in }) == value)
        }
    }
    @Test func receiptRequiresExactRequestRevisionAndFiniteObservedPosition() {
        let request = WebTimestampSeekRequest(identity: timestampIdentity(), position: 20)
        let valid: [String: Any] = ["requestID": request.id.uuidString.lowercased(), "revision": 9, "status": "confirmed", "position": 20.1]
        #expect(WebTimestampSeekOutcome.receipt(valid, request: request, revision: 9) == .confirmed(20.1))
        for (key, value) in [("requestID", UUID().uuidString as Any), ("revision", 8), ("revision", true), ("position", true), ("position", 21), ("position", -1), ("status", "unknown")] {
            var body = valid; body[key] = value
            #expect(WebTimestampSeekOutcome.receipt(body, request: request, revision: 9) == .unconfirmed)
        }
    }
    @Test func missingMalformedAndBooleanClockEvidenceNeverBreaksOrdinaryPlayback() throws {
        let identity = timestampIdentity()
        for clock: Any in [NSNull(), false, "not a clock", ["monotonic": true, "wall": 10], ["monotonic": -1, "wall": 10], ["monotonic": 1]] {
            var value = timestampMessage(identity); value["timestampSeekClock"] = clock
            let message = try #require(PlaybackBridgeMessage.decode(value))
            #expect(message.confirmsEpisodeProgress)
            #expect(WebTimestampSeekIdentity.verified(message, context: identity.context, revision: identity.commandRevision) == nil)
        }
        let message = try #require(PlaybackBridgeMessage.decode(timestampMessage(identity)))
        #expect(WebTimestampSeekIdentity.verified(message, context: identity.context, revision: identity.commandRevision) == identity)
        for (key, value) in [("isAd", true), ("isPlaying", false), ("isBuffering", true), ("mediaReady", false), ("playbackIntent", false)] {
            var body = timestampMessage(identity); body[key] = value
            #expect(WebTimestampSeekIdentity.verified(try #require(PlaybackBridgeMessage.decode(body)), context: identity.context, revision: identity.commandRevision) == nil)
        }
    }
}
private func timestampIdentity() -> WebTimestampSeekIdentity {
    .init(context: .init(engineInstanceID: UUID(), loadID: UUID(), occurrence: .init(sessionID: UUID(), entryID: UUID(), trackID: "abcDEF12_-3", generation: UInt64.max), commandEpoch: UUID(), minimumCommandRevision: 5),
        documentID: UUID(), mediaGeneration: 3, commandRevision: 7, duration: 180, clock: .init(monotonic: 10, wall: 1000))
}
private func nextTimestampContext(_ old: WebTimestampSeekIdentity) -> WebPlaybackOutputContext {
    .init(engineInstanceID: old.context.engineInstanceID, loadID: old.context.loadID, occurrence: old.context.occurrence, commandEpoch: UUID(), minimumCommandRevision: old.commandRevision + 1)
}
private func timestampMessage(_ identity: WebTimestampSeekIdentity) -> [String: Any] {
    let occurrence = identity.context.occurrence
    return ["kind": "progress", "loadID": identity.context.loadID.uuidString, "documentID": identity.documentID.uuidString,
        "identity": ["sessionID": occurrence.sessionID.uuidString, "entryID": occurrence.entryID.uuidString, "trackID": occurrence.trackID, "generation": String(occurrence.generation)],
        "videoID": occurrence.trackID, "sequence": 3, "mediaGeneration": identity.mediaGeneration, "commandRevision": identity.commandRevision,
        "position": 10, "duration": 180, "volume": 1, "playbackIntent": true, "intentSource": "native", "isAd": false, "isPlaying": true, "isBuffering": false, "mediaReady": true,
        "timestampSeekClock": ["monotonic": 10, "wall": 1000]]
}

private final class TimestampObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func mark() { lock.withLock { stored = true } }
}
