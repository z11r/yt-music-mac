import AVFoundation
import Foundation
import ObjectiveC

/// Inert until authorized install; no URL-taking playback initializer or secondary queue.
@MainActor final class NativeLocalAudioPlayerDriver: LocalAudioNativeDriving {
    let outputInstanceID: UUID
    private var player: AVPlayer?
    private var current: NativeLocalAudioItem?
    private var held = false
    init(outputInstanceID: UUID) { self.outputInstanceID = outputInstanceID }
    var snapshot: LocalAudioNativeSnapshot {
        guard let player else { return .init() }
        let known = current.flatMap { player.currentItem === $0.item ? $0 : nil }
        let readiness: LocalAudioNativeReadiness = switch player.currentItem?.status {
        case .readyToPlay: .ready
        case .failed: .failed
        default: .unknown
        }
        let control: LocalAudioNativeControl = switch player.timeControlStatus {
        case .paused: .paused
        case .waitingToPlayAtSpecifiedRate: .waiting
        case .playing: .playing
        @unknown default: .unknown
        }
        func seconds(_ time: CMTime?) -> Double? {
            guard let time, time.isValid, !time.isIndefinite, time.seconds.isFinite else { return nil }
            return time.seconds
        }
        return .init(hasPlayer: true, hasItem: player.currentItem != nil, mediaID: known?.mediaID,
            readiness: readiness, muted: player.isMuted, rate: Double(player.rate), control: control,
            externalPlayback: player.isExternalPlaybackActive,
            position: seconds(player.currentTime()), duration: seconds(player.currentItem?.duration))
    }
    func makeItem(_ source: any LocalAudioPreparedSource) throws -> any LocalAudioNativeItem {
        guard !held, let prepared = source as? PreparedLocalAudioAsset, prepared.lease.acceptsNewUses,
              prepared.asset.url == prepared.lease.fileURL,
              prepared.asset.referenceRestrictions == .forbidAll else { throw LocalAudioPlaybackIssue.unsupported }
        try LocalAudioFilePolicy.validateURL(prepared.asset.url)
        let use = try prepared.lease.retainUse()
        let item = AVPlayerItem(asset: prepared.asset)
        NativeLocalAudioItemLifetime.attach(source: prepared, use: use, to: item)
        return NativeLocalAudioItem(item: item, source: prepared, engine: outputInstanceID)
    }
    func install(_ item: any LocalAudioNativeItem) throws {
        guard !held, let item = item as? NativeLocalAudioItem, item.engine == outputInstanceID else { throw LocalAudioPlaybackIssue.stale }
        if player == nil {
            let value = AVPlayer(); value.isMuted = true; value.volume = 0
            value.allowsExternalPlayback = false; value.actionAtItemEnd = .pause
            player = value
        }
        guard !held, let player else { throw LocalAudioPlaybackIssue.stale }
        player.isMuted = true; player.pause()
        guard !held else { throw LocalAudioPlaybackIssue.stale }
        current = item; player.replaceCurrentItem(with: item.item)
    }
    func detach() { player?.isMuted = true; player?.pause(); current = nil; player?.replaceCurrentItem(with: nil) }
    func mute(_ value: Bool) { guard !held else { return }; player?.isMuted = value }
    func pause() { player?.pause() }
    func play() { guard !held, current?.item === player?.currentItem else { return }; player?.play() }
    func volume(_ value: Double) { guard !held, value.isFinite, (0...1).contains(value) else { return }; player?.volume = Float(value) }
    func seek(_ item: any LocalAudioNativeItem, to position: TimeInterval, completion: @escaping @MainActor (Bool) -> Void) {
        guard !held, let item = item as? NativeLocalAudioItem, current === item, player?.currentItem === item.item else { completion(false); return }
        item.item.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in completion(finished) }
        }
    }
    func cancelSeeks(_ item: any LocalAudioNativeItem) { (item as? NativeLocalAudioItem)?.item.cancelPendingSeeks() }
    func holdOutput() { held = true; if let current { current.item.cancelPendingSeeks() }; detach() }
    func observe(_ item: any LocalAudioNativeItem, receive: @escaping @MainActor (LocalAudioNativeEvent) -> Void) -> any LocalAudioNativeObservation {
        let payload = NativeLocalAudioObservationPayload()
        guard !held, let item = item as? NativeLocalAudioItem, let player, current === item else { return NativeLocalAudioObservation(payload) }
        let state: @Sendable () -> Void = { [weak self, weak item] in
            Task { @MainActor in
                guard let self, let item, self.current === item, self.player?.currentItem === item.item else { return }
                receive(.state(self.snapshot))
            }
        }
        payload.observations = [item.item.observe(\.status, options: [.initial, .new]) { _, _ in state() },
            item.item.observe(\.duration, options: [.new]) { _, _ in state() },
            player.observe(\.timeControlStatus, options: [.new]) { _, _ in state() },
            player.observe(\.rate, options: [.new]) { _, _ in state() },
            player.observe(\.isMuted, options: [.new]) { _, _ in state() }]
        payload.player = player
        payload.time = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { _ in state() }
        for name in [AVPlayerItem.didPlayToEndTimeNotification, AVPlayerItem.failedToPlayToEndTimeNotification] {
            let failed = name == AVPlayerItem.failedToPlayToEndTimeNotification
            payload.notifications.append(NotificationCenter.default.addObserver(forName: name, object: item.item, queue: .main) { [weak self, weak item] _ in
                Task { @MainActor in
                    guard let self, let item, self.current === item, self.player?.currentItem === item.item else { return }
                    receive(failed ? .failed : .ended(self.snapshot))
                }
            })
        }
        return NativeLocalAudioObservation(payload)
    }
    func observeOutput(_ changed: @escaping @MainActor () -> Void) -> any LocalAudioNativeObservation {
        let payload = NativeLocalAudioObservationPayload()
        guard let player else { return NativeLocalAudioObservation(payload) }
        let state: @Sendable () -> Void = { Task { @MainActor in changed() } }
        payload.observations = [player.observe(\.currentItem, options: [.new]) { _, _ in state() },
            player.observe(\.isMuted, options: [.new]) { _, _ in state() },
            player.observe(\.rate, options: [.new]) { _, _ in state() },
            player.observe(\.timeControlStatus, options: [.new]) { _, _ in state() },
            player.observe(\.isExternalPlaybackActive, options: [.new]) { _, _ in state() }]
        return NativeLocalAudioObservation(payload)
    }
}

@MainActor private final class NativeLocalAudioItem: LocalAudioNativeItem {
    let mediaID = UUID()
    let item: AVPlayerItem
    let source: any LocalAudioPreparedSource
    let engine: UUID
    init(item: AVPlayerItem, source: any LocalAudioPreparedSource, engine: UUID) { self.item = item; self.source = source; self.engine = engine }
}
@MainActor private enum NativeLocalAudioItemLifetime {
    private static var key: UInt8 = 0
    private final class Holder {
        let source: any LocalAudioPreparedSource
        let use: LocalAudioResourceUse
        init(source: any LocalAudioPreparedSource, use: LocalAudioResourceUse) { self.source = source; self.use = use }
    }
    static func attach(source: any LocalAudioPreparedSource, use: LocalAudioResourceUse, to item: AVPlayerItem) {
        objc_setAssociatedObject(item, &key, Holder(source: source, use: use), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
@MainActor private final class NativeLocalAudioObservationPayload {
    var observations: [NSKeyValueObservation] = []
    var notifications: [any NSObjectProtocol] = []
    var player: AVPlayer?
    var time: Any?
    func invalidate() {
        observations.forEach { $0.invalidate() }; observations = []
        notifications.forEach(NotificationCenter.default.removeObserver); notifications = []
        if let time, let player { player.removeTimeObserver(time) }
        time = nil; player = nil
    }
}
@MainActor private final class NativeLocalAudioObservation: LocalAudioNativeObservation {
    private let payload: NativeLocalAudioObservationPayload
    init(_ payload: NativeLocalAudioObservationPayload) { self.payload = payload }
    func invalidate() { payload.invalidate() }
    deinit { let payload = payload; Task { @MainActor in payload.invalidate() } }
}
