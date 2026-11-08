import Foundation
import MusicCore

/// The facade controls this exact registered engine. Views and account reads use
/// the separately paired host; they never dispatch transport through that host.
@MainActor protocol WebPlaybackTransport: PlaybackOutputEngine, EpisodeRateControlling {
    var clock: PlaybackClock { get }
    var hasConfirmedPosition: Bool { get }
    var isPlaying: Bool { get }
    var isBuffering: Bool { get }
    var isStartingPlayback: Bool { get }
    var playbackIntent: Bool { get }
    var errorMessage: String? { get }
    var failureReason: PlaybackFailureReason? { get }
    var volume: Double { get }
    var confirmedSegmentIdentity: SponsorBlockPlaybackIdentity? { get }
    var confirmedTimestampIdentity: WebTimestampSeekIdentity? { get }
    var timestampSeekIsReady: Bool { get }
    var timestampSeekIsBusy: Bool { get }
    var outputMediaID: UUID? { get }
    var requestedOutputContext: WebPlaybackOutputContext? { get }
    var currentOutputContext: WebPlaybackOutputContext? { get }
    var isPresented: Bool { get set }
    var onOutputBindingReady: ((WebPlaybackOutputContext) -> Void)? { get set }
    var onOutputEvent: ((WebPlaybackOutputEvent) -> Void)? { get set }
    var onOutputRecoveryRequested: ((WebPlaybackOutputContext, TimeInterval) -> TimeInterval?)? { get set }
    func load(track: Track, occurrence: PlaybackOccurrence, autoplay: Bool)
    func play()
    func pause()
    func seek(to position: TimeInterval)
    func seekSection(_ value: SponsorBlockSeek, completion: @escaping @MainActor (Bool) -> Void)
    func seekTimestamp(_ request: WebTimestampSeekRequest, retarget: () -> Bool, completion: @escaping @MainActor (WebTimestampSeekOutcome) -> Void)
    func setVolume(_ value: Double)
    func invalidateEpisodeRateControl()
}

/// One persistent wrapper per player. Its UUID and retirement receipt refer to
/// that player, with no independent queue, native output or lifecycle authority.
@MainActor final class NativeWebPlaybackEngine: WebPlaybackTransport {
    let player: WebPlayer
    init(player: WebPlayer) { self.player = player }
    var outputInstanceID: UUID { player.outputInstanceID }
    let outputKind = PlaybackOutputEngineKind.web
    var isOutputRetired: Bool { player.isOutputOwnershipHeld }
    var clock: PlaybackClock { player.clock }
    var hasConfirmedPosition: Bool { player.hasConfirmedPosition }
    var isPlaying: Bool { player.isPlaying }
    var isBuffering: Bool { player.isBuffering }
    var isStartingPlayback: Bool { player.isStartingPlayback }
    var playbackIntent: Bool { player.playbackIntent }
    var errorMessage: String? { player.errorMessage }
    var failureReason: PlaybackFailureReason? { player.failureReason }
    var volume: Double { player.volume }
    var confirmedSegmentIdentity: SponsorBlockPlaybackIdentity? { player.confirmedSegmentIdentity }
    var confirmedTimestampIdentity: WebTimestampSeekIdentity? { player.confirmedTimestampIdentity }
    var timestampSeekIsReady: Bool { player.timestampSeekIsReady }
    var timestampSeekIsBusy: Bool { player.timestampSeekIsBusy }
    var outputMediaID: UUID? { player.outputMediaID }
    var requestedOutputContext: WebPlaybackOutputContext? { player.requestedOutputContext }
    var currentOutputContext: WebPlaybackOutputContext? { player.currentOutputContext }
    var isPresented: Bool { get { player.isPresented } set { player.isPresented = newValue } }
    var onOutputBindingReady: ((WebPlaybackOutputContext) -> Void)? {
        get { player.onOutputBindingReady } set { player.onOutputBindingReady = newValue }
    }
    var onOutputEvent: ((WebPlaybackOutputEvent) -> Void)? {
        get { player.onOutputEvent } set { player.onOutputEvent = newValue }
    }
    var onOutputRecoveryRequested: ((WebPlaybackOutputContext, TimeInterval) -> TimeInterval?)? {
        get { player.onOutputRecoveryRequested } set { player.onOutputRecoveryRequested = newValue }
    }
    func load(track: Track, occurrence: PlaybackOccurrence, autoplay: Bool) { player.load(track: track, occurrence: occurrence, autoplay: autoplay) }
    func play() { player.play() }
    func pause() { player.pause() }
    func seek(to position: TimeInterval) { player.seek(to: position) }
    func seekSection(_ value: SponsorBlockSeek, completion: @escaping @MainActor (Bool) -> Void) { player.seekSection(value, completion: completion) }
    func seekTimestamp(_ request: WebTimestampSeekRequest, retarget: () -> Bool, completion: @escaping @MainActor (WebTimestampSeekOutcome) -> Void) {
        player.seekTimestamp(request, retarget: retarget, completion: completion)
    }
    func setVolume(_ value: Double) { player.setVolume(value) }
    func invalidateEpisodeRateControl() { player.invalidateEpisodeRateControl() }
    func setEpisodeRate(_ rate: Double, occurrence: PlaybackOccurrence) async -> Bool { await player.setEpisodeRate(rate, occurrence: occurrence) }
    func refreshEpisodeRates(occurrence: PlaybackOccurrence) { player.refreshEpisodeRates(occurrence: occurrence) }
    func invalidateOutputScopes(_ effect: PlaybackOutputRetargetEffect) { player.invalidateOutputScopesForRetarget(effect) }
    func revokeOutput() -> PlaybackOutputRetirement { player.revokeOutputForHandoff() }
}

/// Production creates the wrapper from its host. Tests may pair an inert host
/// with a controlled transport carrying that same stable instance identifier.
@MainActor struct WebPlaybackInstance {
    let host: WebPlayer
    let transport: any WebPlaybackTransport
    init(host: WebPlayer) {
        self.host = host; transport = NativeWebPlaybackEngine(player: host)
    }
    init(host: WebPlayer, transport: any WebPlaybackTransport) {
        precondition(host.outputInstanceID == transport.outputInstanceID && transport.outputKind == .web)
        self.host = host; self.transport = transport
    }
}
