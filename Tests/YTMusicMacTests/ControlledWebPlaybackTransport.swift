import Foundation
import MusicCore
@testable import YTMusicMac

/// A reusable facade test boundary. No WK object, player, I/O, timer or preferences.
/// Native messages pass through the production observation and event gates.
@MainActor final class ControlledWebPlaybackTransport: WebPlaybackTransport {
    enum Action: Equatable {
        case load(PlaybackOccurrence, autoplay: Bool), play, pause, seek(Double), volume(Double)
        case retarget(PlaybackOutputRetargetEffect), retire, recovery(Double), timestamp(Double)
    }
    let outputInstanceID: UUID
    let outputKind = PlaybackOutputEngineKind.web
    private(set) var isOutputRetired = false
    let clock = PlaybackClock()
    private(set) var hasConfirmedPosition = false
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var isStartingPlayback = false
    private(set) var playbackIntent = false
    private(set) var errorMessage: String?
    private(set) var failureReason: PlaybackFailureReason?
    private(set) var volume: Double = 1
    var confirmedSegmentIdentity: SponsorBlockPlaybackIdentity? { nil }
    private(set) var confirmedTimestampIdentity: WebTimestampSeekIdentity?
    private let timestampTransaction = WebTimestampSeekTransaction(admission: WebTimestampSeekAdmission())
    var timestampSeekIsReady: Bool { confirmedTimestampIdentity != nil }
    var timestampSeekIsBusy: Bool { timestampTransaction.isBusy }
    private var timestampCompletion: (@MainActor (WebTimestampSeekOutcome) -> Void)?
    func finishTimestamp(_ outcome: WebTimestampSeekOutcome) { let callback = timestampCompletion; timestampCompletion = nil; callback?(outcome) }
    var outputMediaID: UUID? { gate.loadID }
    var requestedOutputContext: WebPlaybackOutputContext? { observation.requested }
    var currentOutputContext: WebPlaybackOutputContext? { observation.current }
    var isPresented = false
    var onOutputBindingReady: ((WebPlaybackOutputContext) -> Void)?
    var onOutputEvent: ((WebPlaybackOutputEvent) -> Void)?
    var onOutputRecoveryRequested: ((WebPlaybackOutputContext, TimeInterval) -> TimeInterval?)?
    var automaticallyAcknowledgesLoads = false
    var automaticallyAcknowledgesCommands = false
    var automaticallyConfirmsRetirement = true
    private(set) var actions: [Action] = []
    private(set) var retirement: PlaybackOutputRetirement?
    private var observation = WebPlaybackOutputObservation()
    private var gate = PlaybackEventGate()
    private var document = UUID(), epoch = UUID()
    private var revision = 0, minimum = 0, sequence = 0
    private var occurrence: PlaybackOccurrence?

    init(instanceID: UUID = UUID()) { outputInstanceID = instanceID }
    func load(track: Track, occurrence: PlaybackOccurrence, autoplay: Bool) {
        guard !isOutputRetired, track.id == occurrence.trackID else { return }
        actions.append(.load(occurrence, autoplay: autoplay)); self.occurrence = occurrence
        playbackIntent = autoplay; isPlaying = false; isBuffering = autoplay; isStartingPlayback = autoplay
        errorMessage = nil; failureReason = nil; hasConfirmedPosition = false; clock.reset()
        beginLoad(occurrence)
        if automaticallyAcknowledgesLoads { acknowledge() }
    }
    private func beginLoad(_ occurrence: PlaybackOccurrence) {
        revision = 0; minimum = 0; sequence = 0; document = UUID(); epoch = UUID()
        gate.activate(loadID: UUID(), occurrence: occurrence); gate.bind(documentID: document)
        prepareContext()
    }
    private func prepareContext() {
        guard let load = gate.loadID, let occurrence else { observation.revoke(); return }
        observation.prepare(.init(engineInstanceID: outputInstanceID, loadID: load, occurrence: occurrence,
            commandEpoch: epoch, minimumCommandRevision: minimum))
    }
    func play() {
        guard !isOutputRetired, occurrence != nil else { return }
        actions.append(.play); playbackIntent = true; isStartingPlayback = !isPlaying; issueCommand()
    }
    func pause() {
        guard !isOutputRetired, occurrence != nil else { return }
        actions.append(.pause); playbackIntent = false; isPlaying = false; isBuffering = false; isStartingPlayback = false
        issueCommand()
    }
    func seek(to position: TimeInterval) {
        guard !isOutputRetired, occurrence != nil, position.isFinite, position >= 0 else { return }
        actions.append(.seek(position)); issueCommand()
    }
    func seekSection(_ value: SponsorBlockSeek, completion: @escaping @MainActor (Bool) -> Void) { completion(false) }
    func seekTimestamp(_ request: WebTimestampSeekRequest, retarget: () -> Bool, completion: @escaping @MainActor (WebTimestampSeekOutcome) -> Void) {
        timestampTransaction.perform(request, current: { confirmedTimestampIdentity }, retarget: {
            guard retarget() else { return nil }; return requestedOutputContext
        }, dispatch: { request, context, finish in
            actions.append(.timestamp(request.position)); revision += 1; observation.commandIssued(revision)
            let issued = revision
            acknowledge(position: clock.position, playing: true)
            timestampCompletion = { [weak self] outcome in
                guard let self, self.currentOutputContext == context, self.revision == issued, !self.isOutputRetired else {
                    finish(.unconfirmed); return
                }
                finish(outcome)
            }
        }, completion: completion)
    }
    func setVolume(_ value: Double) {
        guard !isOutputRetired, value.isFinite else { return }
        volume = min(1, max(0, value)); actions.append(.volume(volume))
        if occurrence != nil { issueCommand() }
    }
    private func issueCommand() {
        revision += 1; observation.commandIssued(revision)
        if automaticallyAcknowledgesCommands { acknowledge() }
    }
    func invalidateOutputScopes(_ effect: PlaybackOutputRetargetEffect) {
        guard !isOutputRetired else { return }
        confirmedTimestampIdentity = nil
        actions.append(.retarget(effect)); epoch = UUID(); revision += 1; minimum = revision
        prepareContext()
        if effect == .nextItemPreparation { isPlaying = false; playbackIntent = false; isBuffering = false }
    }
    /// Explicit synthetic native acknowledgment; calling controls alone need not acknowledge.
    func acknowledge(position: Double = 1, duration: Double = 180, playing: Bool? = nil, kind: String = "state") {
        guard !isOutputRetired, let context = requestedOutputContext else { return }
        sequence += 1
        let playing = playing ?? playbackIntent
        let body: [String: Any] = [
            "kind": kind, "loadID": context.loadID.uuidString, "documentID": document.uuidString,
            "identity": ["sessionID": context.occurrence.sessionID.uuidString, "entryID": context.occurrence.entryID.uuidString,
                         "trackID": context.occurrence.trackID, "generation": String(context.occurrence.generation)],
            "mediaGeneration": 1, "sequence": sequence, "commandRevision": revision,
            "playbackIntent": playbackIntent, "intentSource": "native", "videoID": context.occurrence.trackID,
            "position": position, "duration": duration, "volume": volume,
            "isPlaying": playing, "isBuffering": false, "isAd": false, "mediaReady": true,
            "timestampSeekClock": ["monotonic": sequence * 10, "wall": 1000 + sequence * 10],
        ]
        guard let message = PlaybackBridgeMessage.decode(body), let receipt = observation.accept(message, gate: &gate) else { return }
        if receipt.needsBinding { onOutputBindingReady?(receipt.context) }
        guard observation.accepts(receipt.context) else { return }
        isPlaying = playing; isBuffering = false; isStartingPlayback = false
        hasConfirmedPosition = true; clock.update(position: position, duration: duration)
        confirmedTimestampIdentity = WebTimestampSeekIdentity.verified(message, context: receipt.context, revision: revision)
        if message.interruptsPlaybackOutput { onOutputEvent?(.init(context: receipt.context, kind: .outputInterrupted)) }
        guard observation.accepts(receipt.context) else { return }
        if !message.confirmsEpisodeProgress || (message.kind != .progress && message.kind != .ended) {
            onOutputEvent?(.init(context: receipt.context, kind: .listeningInterrupted))
        }
        guard observation.accepts(receipt.context) else { return }
        if message.confirmsEpisodeProgress {
            onOutputEvent?(.init(context: receipt.context, kind: .progress(position: position, duration: duration, ended: kind == "ended")))
        }
        guard observation.accepts(receipt.context) else { return }
        onOutputEvent?(.init(context: receipt.context, kind: .state))
        if kind == "ended", observation.accepts(receipt.context) { onOutputEvent?(.init(context: receipt.context, kind: .ended)) }
    }
    @discardableResult func requestRecovery(position: Double) -> Bool {
        guard !isOutputRetired, let context = currentOutputContext,
              let retained = onOutputRecoveryRequested?(context, position), currentOutputContext == context,
              retained.isFinite, retained >= 0 else { return false }
        actions.append(.recovery(retained)); hasConfirmedPosition = false
        isPlaying = false; isBuffering = playbackIntent; isStartingPlayback = playbackIntent
        beginLoad(context.occurrence); return true
    }
    func failBeforeAcknowledgment(_ message: String = "Synthetic load failure") {
        guard !isOutputRetired, let context = requestedOutputContext else { return }
        errorMessage = message; failureReason = .navigationFailed; playbackIntent = false; isPlaying = false
        isBuffering = false; isStartingPlayback = false
        onOutputEvent?(.init(context: context, kind: .failure(message: message, reason: .navigationFailed)))
    }
    func revokeOutput() -> PlaybackOutputRetirement {
        if let retirement { return retirement }
        isOutputRetired = true; confirmedTimestampIdentity = nil; observation.revoke(); gate = PlaybackEventGate()
        playbackIntent = false; isPlaying = false; isBuffering = false; isStartingPlayback = false
        hasConfirmedPosition = false; clock.reset(); actions.append(.retire)
        let value = PlaybackOutputRetirement(engine: .web, instanceID: outputInstanceID, sleep: { throw CancellationError() })
        retirement = value
        if automaticallyConfirmsRetirement { value.confirmQuiet(ticket: value.ticket) }
        return value
    }
    func confirmRetirement() { if let retirement { retirement.confirmQuiet(ticket: retirement.ticket) } }
    func timeOutRetirement() { retirement?.block(.timedOut) }
    func invalidateEpisodeRateControl() {}
    func setEpisodeRate(_ rate: Double, occurrence: PlaybackOccurrence) async -> Bool { false }
    func refreshEpisodeRates(occurrence: PlaybackOccurrence) {}
}
