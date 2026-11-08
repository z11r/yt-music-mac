import Foundation
import MusicCore
import Observation
import WebKit

/// The session owns this transport. Engines own output, never queue navigation.
@MainActor @Observable
final class PlaybackController: EpisodeRateControlling {
    struct Owner: Equatable {
        let profile: UUID
        let account: UUID
    }
    struct WebHostIdentity: Hashable {
        let instance: UUID
        let generation: Int
    }
    @ObservationIgnored var owner: (() -> Owner?)?
    @ObservationIgnored var acceptsOccurrence: ((PlaybackOccurrence) -> Bool)?
    @ObservationIgnored var onEnded: ((PlaybackOccurrence) -> Void)?
    @ObservationIgnored var onFailure: (() -> Void)?
    @ObservationIgnored var onPageReady: ((WKWebView) -> Void)?
    @ObservationIgnored var onStateChanged: (() -> Void)?
    @ObservationIgnored var onVerifiedContentProgress: ((PlaybackOccurrence, TimeInterval, TimeInterval, Bool) -> Void)?
    @ObservationIgnored var onEpisodeRates: ((PlaybackOccurrence, EpisodeRateSnapshot?) -> Void)?
    @ObservationIgnored var onListeningInterrupted: ((PlaybackOccurrence) -> Void)?
    @ObservationIgnored var onPlaybackOutputInterrupted: ((PlaybackOccurrence) -> Void)?
    @ObservationIgnored var onRecoveryRequested: ((PlaybackOccurrence, TimeInterval) -> TimeInterval?)?
    @ObservationIgnored var onSessionRestoreFailed: (() -> Void)?
    private(set) var web: WebPlayer
    private(set) var volume: Double = 1
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var isStartingPlayback = false
    private(set) var playbackIntent = false
    private(set) var errorMessage: String?
    private(set) var failureReason: PlaybackFailureReason?
    private(set) var activeKind: PlaybackOutputEngineKind?
    var isPresented = false { didSet { webTransport.isPresented = isPresented && activeKind != .local } }
    private let transitionClock = PlaybackClock()
    var clock: PlaybackClock {
        guard !isPreparing else { return transitionClock }
        switch activeKind { case .web: return webTransport.clock; case .local: return local?.clock ?? transitionClock; case nil: return transitionClock }
    }
    var hasConfirmedPosition: Bool {
        guard !isPreparing else { return false }
        switch activeKind { case .web: return webTransport.hasConfirmedPosition; case .local: return local?.hasConfirmedPosition ?? false; case nil: return false }
    }
    var webView: WKWebView { web.webView }
    var webViewGeneration: Int { web.webViewGeneration }
    var webHostIdentity: WebHostIdentity { .init(instance: web.outputInstanceID, generation: web.webViewGeneration) }
    var videoPresentation: VideoPresentationController { web.videoPresentation }
    var confirmedSegmentIdentity: SponsorBlockPlaybackIdentity? { activeKind == .web && !isPreparing ? webTransport.confirmedSegmentIdentity : nil }
    @ObservationIgnored private let sessionID = UUID()
    @ObservationIgnored private let makeWeb: () -> WebPlaybackInstance
    @ObservationIgnored private let outputIsEnabled: Bool
    @ObservationIgnored private let admission: PlaybackOutputAdmission
    @ObservationIgnored private let localConfiguration: LocalAudioPlaybackConfiguration?
    @ObservationIgnored private var coordinator: PlaybackOutputCoordinator!
    @ObservationIgnored private var webTransport: any WebPlaybackTransport
    @ObservationIgnored private var local: LocalAudioPlayerEngine?
    @ObservationIgnored private var lastLocalEventBindingID: UUID?
    @ObservationIgnored private var webContext: WebPlaybackOutputContext?
    @ObservationIgnored private var webBinding: PlaybackOutputEventBinding?
    @ObservationIgnored private var permit: PlaybackOutputPermit?
    @ObservationIgnored private var scope: PlaybackOutputScope?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var workID: UUID?
    @ObservationIgnored private var preparationWorkers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var stopping: Task<PlaybackOutputSettlement, Never>?
    @ObservationIgnored private var retiringCoordinator: PlaybackOutputCoordinator?
    @ObservationIgnored private var unboundWebRetirement: PlaybackOutputRetirement?
    @ObservationIgnored private var resumePosition: TimeInterval = 0
    @ObservationIgnored private var preparingSeekRevision: UInt64 = 0
    @ObservationIgnored private var isQuiesced = false
    private(set) var isPreparing = false

    init(dataStore: WKWebsiteDataStore, admission: PlaybackOutputAdmission,
         outputIsEnabled: Bool = false, local: LocalAudioPlaybackConfiguration? = nil,
         webFactory: (() -> WebPlaybackInstance)? = nil) {
        self.admission = admission; self.outputIsEnabled = outputIsEnabled; localConfiguration = local
        let factory = webFactory ?? { WebPlaybackInstance(host: WebPlayer(dataStore: dataStore)) }
        makeWeb = factory
        let initial = factory()
        web = initial.host; webTransport = initial.transport
        replaceCoordinator(); connectWeb(initial)
    }

    private func replaceCoordinator() {
        coordinator = PlaybackOutputCoordinator(admission: admission) { [weak self] scope in self?.isCurrent(scope) == true }
    }
    private func isCurrent(_ value: PlaybackOutputScope) -> Bool {
        guard !isQuiesced, scope == value, owner?() == Owner(profile: value.profileGeneration, account: value.accountGeneration),
              acceptsOccurrence?(value.occurrence) == true else { return false }
        return value.sessionID == sessionID
    }
    private func makeScope(track: Track, occurrence: PlaybackOccurrence) -> PlaybackOutputScope? {
        guard let owner = owner?(), acceptsOccurrence?(occurrence) == true,
              track.id == occurrence.trackID, revision < UInt64.max else { return nil }
        revision += 1
        return .init(sessionID: sessionID, profileGeneration: owner.profile, accountGeneration: owner.account,
                     occurrence: occurrence, engine: track.hasLocalAudioSource ? .local : .web,
                     itemID: UUID(), intentRevision: revision)
    }

    func load(track: Track, occurrence: PlaybackOccurrence, autoplay: Bool = true) {
        guard outputIsEnabled, !isQuiesced, let next = makeScope(track: track, occurrence: occurrence) else { return }
        work?.cancel(); work = nil; workID = nil
        if isPreparing, scope != nil { beginRetirement() }
        let id = UUID(); requestID = id; scope = next; webBinding = nil; webContext = nil
        lastLocalEventBindingID = nil
        resumePosition = 0; preparingSeekRevision = 0; playbackIntent = autoplay; isPlaying = false; isBuffering = autoplay
        isStartingPlayback = autoplay; isPreparing = true; errorMessage = nil; failureReason = nil; transitionClock.reset()
        // Readers retain their real profile/file leases after cancellation.
        // They do not own output admission, and at most four source operations
        // remain retained; no chain of canceled requests is created.
        guard preparationWorkers.count < 4 else { failHandoff(next); return }
        let task = Task { [weak self] in
            defer { self?.completedPreparation(id) }
            guard let self, self.requestID == id, self.isCurrent(next), !Task.isCancelled else { return }
            if let stopping = self.stopping {
                _ = await stopping.value
                let result = await self.retirementSettlement()
                guard self.requestID == id, self.isCurrent(next), !Task.isCancelled else { return }
                guard result == .quiet else { self.failHandoff(next); return }
                self.stopping = nil; self.retiringCoordinator = nil; self.replaceCoordinator()
            }
            await self.prepare(track: track, scope: next, request: id)
        }
        work = task; workID = id; preparationWorkers[id] = task
    }
    private func completedPreparation(_ id: UUID) {
        preparationWorkers[id] = nil
        if workID == id { work = nil; workID = nil }
    }

    private func prepare(track: Track, scope next: PlaybackOutputScope, request id: UUID) async {
        let coordinator = self.coordinator!
        // Cancellation can leave an unregistered startup view retiring. It is
        // still an output barrier for every source, including another web load.
        if let operation = unboundWebRetirement {
            _ = await operation.settle()
            guard isCurrent(next), requestID == id, !Task.isCancelled else { return }
            guard operation.isConfirmedQuiet else { failHandoff(next); return }
        }
        let bound: PlaybackOutputPermit
        if let old = permit, old.scope.engine == next.engine,
           old.scope.profileGeneration == next.profileGeneration, old.scope.accountGeneration == next.accountGeneration,
           !((next.engine == .web && webTransport.isOutputRetired) || (next.engine == .local && local?.isOutputRetired == true)) {
            switch coordinator.retargetOutput(old, to: next) {
            case let .permitted(value): bound = value
            case .blocked: failHandoff(next); return
            }
        } else {
            // The startup account page never received a playback permit. It
            // still has to acknowledge permanent suspension before local output.
            if next.engine == .local, permit == nil {
                let retirement = unboundWebRetirement ?? webTransport.revokeOutput()
                unboundWebRetirement = retirement
                _ = await retirement.settle()
                guard isCurrent(next), requestID == id, !Task.isCancelled else { return }
                guard retirement.isConfirmedQuiet else { failHandoff(next); return }
            }
            let reservation: PreparedPlaybackOutputPermit
            switch await coordinator.prepareOutput(next) {
            case let .prepared(value): reservation = value
            case .blocked:
                // A canceled cross-source retirement permanently revokes that
                // coordinator. Carry its retained output into bounded settlement.
                if self.coordinator === coordinator, stopping == nil { beginRetirement() }
                if isCurrent(next) { failHandoff(next) }; return
            }
            guard isCurrent(next), requestID == id, !Task.isCancelled else {
                _ = coordinator.cancelPreparedOutput(reservation); return
            }
            let engine: any PlaybackOutputEngine
            if next.engine == .web {
                if webTransport.isOutputRetired {
                    let replacement = makeWeb(); web = replacement.host
                    webTransport = replacement.transport; connectWeb(replacement)
                }
                engine = webTransport
            } else {
                guard let configuration = localConfiguration else {
                    _ = coordinator.cancelPreparedOutput(reservation); failLocal(next, issue: .unavailable); return
                }
                if local == nil || local?.isOutputRetired == true {
                    let coordinator = self.coordinator!
                    let engine = configuration.makeEngine({ [weak coordinator] permit, engine, mediaID in
                        coordinator?.bindMediaEvents(permit, engine: engine, nativeMediaID: mediaID)
                    }, { [weak coordinator] in coordinator?.acceptsEvent($0) == true })
                    engine.onEvent = { [weak self] event in self?.receiveLocal(event) }
                    local = engine
                }
                guard let local else { _ = coordinator.cancelPreparedOutput(reservation); failHandoff(next); return }
                engine = local
            }
            switch coordinator.bindOutput(reservation, to: engine) {
            case let .permitted(value): bound = value
            case .blocked: _ = coordinator.cancelPreparedOutput(reservation); failHandoff(next); return
            }
        }
        permit = bound; activeKind = next.engine
        guard isCurrent(next), bound.isCurrent, !Task.isCancelled else { return }
        if next.engine == .web {
            guard track.isServiceTrack else { failLocal(next, issue: .unsupported); return }
            webTransport.isPresented = isPresented
            webTransport.setVolume(volume)
            webTransport.load(track: track, occurrence: next.occurrence, autoplay: playbackIntent)
            guard isCurrent(next), bound.isCurrent, webTransport.outputMediaID != nil else { failHandoff(next); return }
            // The exact page must acknowledge its load before it can publish
            // playback events. Synchronous load callbacks carry no authority.
            if resumePosition > 0 { webTransport.seek(to: resumePosition) }
        } else if let configuration = localConfiguration, let local {
            let authorization = LocalAudioIOAuthorization(profileStorageID: configuration.profileStorageID) { [weak self] in
                self?.isCurrent(next) == true && bound.isCurrent
            }
            let prepared = await configuration.prepare(track, next, authorization, resumePosition)
            guard isCurrent(next), requestID == id, bound.isCurrent, !Task.isCancelled else {
                if case let .success(value) = prepared { value.cancelIfUnconsumed() }; return
            }
            switch prepared {
            case let .failure(issue): failLocal(next, issue: issue)
            case let .success(item):
                // Preparation always installs paused. A later Pause wins over
                // an earlier asynchronous Play request.
                let result = await local.activate(item, permit: bound, autoplay: false, volume: volume)
                guard isCurrent(next), requestID == id, bound.isCurrent, !Task.isCancelled else { return }
                switch result {
                case let .failure(issue): failLocal(next, issue: issue)
                case .success:
                    var applied = item.resumePosition
                    var seeks = 0
                    while resumePosition != applied {
                        guard seeks < 8 else { failLocal(next, issue: .busy); return }
                        seeks += 1
                        let seekRevision = preparingSeekRevision
                        let target = min(resumePosition, local.clock.duration)
                        let result = await local.seek(target, permit: bound)
                        guard isCurrent(next), requestID == id, bound.isCurrent, !Task.isCancelled else { return }
                        if case let .failure(issue) = result { failLocal(next, issue: issue); return }
                        applied = seekRevision == preparingSeekRevision ? resumePosition : target
                    }
                    isPreparing = false; isStartingPlayback = false; isBuffering = false
                    if playbackIntent { handle(local.play(permit: bound, volume: volume), scope: next) }
                    else { onStateChanged?() }
                }
            }
        }
    }

    private func commandPermit(optionalAction: Bool = false) -> PlaybackOutputPermit? {
        guard let previous = permit, let current = scope, previous.scope == current,
              isCurrent(current), revision < UInt64.max else { return nil }
        revision += 1
        let next = PlaybackOutputScope(sessionID: current.sessionID, profileGeneration: current.profileGeneration,
            accountGeneration: current.accountGeneration, occurrence: current.occurrence, engine: current.engine,
            itemID: current.itemID, intentRevision: revision)
        let previousBinding = webBinding, previousContext = webContext
        scope = next; webBinding = nil; webContext = nil
        switch coordinator.retargetOutput(previous, to: next) {
        case let .permitted(value): permit = value; return value
        case .blocked:
            if !optionalAction { failHandoff(next) }
            else if previous.isCurrent { scope = current; webBinding = previousBinding; webContext = previousContext }
            return nil
        }
    }

    func canResume(_ occurrence: PlaybackOccurrence?) -> Bool {
        guard let occurrence, let scope, scope.occurrence == occurrence, isCurrent(scope), stopping == nil else { return false }
        return isPreparing || permit?.isCurrent == true
    }

    func play() {
        guard !isQuiesced, let scope, isCurrent(scope) else { return }
        playbackIntent = true
        if isPreparing { isStartingPlayback = true; isBuffering = true; onStateChanged?(); return }
        guard let permit = commandPermit() else { return }
        if activeKind == .web { webTransport.play() }
        else if let local { handle(local.play(permit: permit, volume: volume), scope: permit.scope) }
    }
    func pause() {
        playbackIntent = false; isStartingPlayback = false; isPlaying = false; isBuffering = false
        if activeKind == .web, permit?.isCurrent == true {
            // Pause invalidates the previous page intent before any old bind,
            // progress or end message can acquire output authority.
            if commandPermit() != nil { webTransport.pause() }
        } else if !isPreparing, let permit, permit.isCurrent, let local {
            // Preserve an admitted local seek while pausing its exact item.
            handle(local.pause(permit: permit), scope: permit.scope)
        }
        onStateChanged?()
    }
    func seek(to value: TimeInterval) {
        guard !isQuiesced, value.isFinite, value >= 0 else { return }
        if isPreparing {
            resumePosition = value; preparingSeekRevision &+= 1
            if activeKind == .web, permit?.isCurrent == true { webTransport.seek(to: value) }
            return
        }
        guard let permit = commandPermit() else { return }
        if activeKind == .web { webTransport.seek(to: value) }
        else if let local {
            Task { [weak self] in
                let result = await local.seek(value, permit: permit)
                guard let self, self.permit === permit, permit.isCurrent else { return }
                self.handle(result, scope: permit.scope)
            }
        }
    }
    func seekSection(_ value: SponsorBlockSeek, completion: @escaping @MainActor (Bool) -> Void) {
        guard activeKind == .web, !isPreparing, let permit, permit.isCurrent else { completion(false); return }
        webTransport.seekSection(value) { success in completion(success && permit.isCurrent) }
    }
    var timestampSeekIsReady: Bool {
        activeKind == .web && !isPreparing && !isQuiesced && webTransport.timestampSeekIsReady && !webTransport.timestampSeekIsBusy
    }
    func timestampSeekTarget(position: TimeInterval) -> PlaybackTimestampSeekTarget? {
        guard !webTransport.timestampSeekIsBusy, let identity = webTransport.confirmedTimestampIdentity, acceptsWeb(identity.context),
              let permit, permit.isCurrent, permit.authorizes(webTransport), let binding = webBinding else { return nil }
        let request = WebTimestampSeekRequest(identity: identity, position: position)
        guard request.isValid else { return nil }
        return .init(scope: permit.scope, bindingID: binding.id, request: request)
    }
    func canSeekTimestamp(_ target: PlaybackTimestampSeekTarget) -> Bool {
        guard !isQuiesced, target.request.isValid, let permit, permit.isCurrent, permit.scope == target.scope,
              permit.authorizes(webTransport), webBinding?.id == target.bindingID,
              acceptsWeb(target.request.identity.context), webTransport.confirmedTimestampIdentity == target.request.identity else { return false }
        return true
    }
    func seekTimestamp(_ target: PlaybackTimestampSeekTarget, completion: @escaping @MainActor (WebTimestampSeekOutcome) -> Void) {
        guard !webTransport.timestampSeekIsBusy, canSeekTimestamp(target) else { completion(.rejected); return }
        var admitted: PlaybackOutputPermit?
        webTransport.seekTimestamp(target.request, retarget: {
            guard self.canSeekTimestamp(target) else { return false }
            admitted = self.commandPermit(optionalAction: true)
            return admitted != nil
        }) { [weak self] outcome in
            guard let self, let admitted, self.permit === admitted, admitted.isCurrent, self.isCurrent(admitted.scope) else {
                completion(.unconfirmed); return
            }
            completion(outcome)
        }
    }
    func setVolume(_ value: Double) {
        guard value.isFinite else { return }; volume = min(1, max(0, value))
        if isPreparing {
            if activeKind == .web, permit?.isCurrent == true { webTransport.setVolume(volume) }
            return
        }
        guard let permit, permit.isCurrent else { return }
        if activeKind == .web { webTransport.setVolume(volume) }
        else if let local { handle(local.setVolume(volume, permit: permit), scope: permit.scope) }
    }
    func stop() {
        work?.cancel(); work = nil; workID = nil; requestID = UUID(); scope = nil; webBinding = nil; webContext = nil
        playbackIntent = false; isPlaying = false; isBuffering = false; isStartingPlayback = false; isPreparing = false
        transitionClock.reset(); activeKind = nil; errorMessage = nil; failureReason = nil
        beginRetirement(); onStateChanged?()
    }
    func refuseServiceItem() {
        stop()
        errorMessage = AppLocalization.text("Sign in to play this service item, or select another queue entry.")
        failureReason = .playbackBlocked
        onStateChanged?()
    }
    func invalidateOwner() { if scope != nil { stop() } }
    func quiesce() { isQuiesced = true; stop() }
    func resumePausedOwnership() {
        // Permanent holds remain held; a later explicit request constructs a new engine.
        isQuiesced = false
    }
    private func beginRetirement() {
        guard stopping == nil else { return }
        let previous = coordinator!
        previous.quiesce(); permit = nil; retiringCoordinator = previous
        guard outputIsEnabled else { stopping = Task { .quiet }; return }
        let webReceipt = webTransport.revokeOutput(); unboundWebRetirement = webReceipt
        stopping = Task {
            let output = await previous.settle()
            _ = await webReceipt.settle()
            return output == .quiet && webReceipt.isConfirmedQuiet ? .quiet : .blocked(.unconfirmed)
        }
    }
    private func retirementSettlement() async -> PlaybackOutputSettlement {
        guard outputIsEnabled else { return .quiet }
        let result = await retiringCoordinator?.settle() ?? .quiet
        if let operation = unboundWebRetirement {
            _ = await operation.settle()
            guard operation.isConfirmedQuiet else { return .blocked(.unconfirmed) }
        }
        return result
    }
    func waitForPreparation() async { await work?.value }
    func settleOutput() async -> PlaybackOutputSettlement {
        if let stopping { _ = await stopping.value; return await retirementSettlement() }
        return await coordinator.settle()
    }
    func canReadAccountContext(from view: WKWebView) -> Bool {
        !isQuiesced && !webTransport.isOutputRetired && activeKind != .local && scope?.engine != .local && web.webView === view
    }
    @discardableResult func restoreSessionPage(synchronize: @escaping @MainActor (WKWebView) async -> Bool) -> Bool {
        guard outputIsEnabled, !isQuiesced, activeKind != .local, scope == nil, stopping == nil, !webTransport.isOutputRetired else { return false }
        return web.restoreSessionPage(synchronize: synchronize)
    }
    func cancelSessionRestore() { web.cancelSessionRestore() }
    func invalidateEpisodeRateControl() { webTransport.invalidateEpisodeRateControl() }
    func setEpisodeRate(_ rate: Double, occurrence: PlaybackOccurrence) async -> Bool {
        guard activeKind == .web, !isPreparing, let permit, permit.isCurrent, permit.scope.occurrence == occurrence else { return false }
        let result = await webTransport.setEpisodeRate(rate, occurrence: occurrence)
        return result && permit.isCurrent
    }
    func refreshEpisodeRates(occurrence: PlaybackOccurrence) {
        guard activeKind == .web, !isPreparing, permit?.isCurrent == true else { return }
        webTransport.refreshEpisodeRates(occurrence: occurrence)
    }

    private func connectWeb(_ instance: WebPlaybackInstance) {
        let transport = instance.transport
        let player = instance.host
        transport.onOutputBindingReady = { [weak self, weak transport] context in
            guard let self, let transport, self.webTransport === transport, self.activeKind == .web,
                  let permit = self.permit, permit.isCurrent, self.isCurrent(permit.scope),
                  context.engineInstanceID == self.web.outputInstanceID,
                  context.occurrence == permit.scope.occurrence,
                  self.webTransport.currentOutputContext == context else { return }
            guard let binding = self.coordinator.bindMediaEvents(permit, engine: self.webTransport, nativeMediaID: context.loadID) else { return }
            self.webContext = context; self.webBinding = binding; self.isPreparing = false
            if self.webTransport.volume != self.volume { self.webTransport.setVolume(self.volume) }
            if self.webTransport.playbackIntent != self.playbackIntent {
                let desired = self.playbackIntent
                guard self.commandPermit() != nil else { return }
                self.isPreparing = true; self.isStartingPlayback = desired; self.isBuffering = desired
                if desired { self.webTransport.play() } else { self.webTransport.pause() }
            }
        }
        transport.onOutputEvent = { [weak self, weak transport] event in
            guard let self, let transport, self.webTransport === transport else { return }
            self.receiveWeb(event)
        }
        transport.onOutputRecoveryRequested = { [weak self, weak transport] context, position in
            guard let self, let transport, self.webTransport === transport, self.acceptsWeb(context),
                  let retained = self.onRecoveryRequested?(context.occurrence, position) else { return nil }
            self.webContext = nil; self.webBinding = nil; self.isPreparing = true
            self.transitionClock.reset(); self.isStartingPlayback = self.playbackIntent
            self.isPlaying = false; self.isBuffering = self.playbackIntent
            self.onListeningInterrupted?(context.occurrence)
            self.onPlaybackOutputInterrupted?(context.occurrence)
            self.onStateChanged?()
            return retained
        }
        player.onPageReady = { [weak self, weak player] view in
            guard let self, self.web === player, !self.isQuiesced, self.activeKind != .local, !self.webTransport.isOutputRetired else { return }
            self.onPageReady?(view)
        }
        player.onSessionRestoreFailed = { [weak self, weak player] in
            guard let self, self.web === player, !self.isQuiesced, !self.webTransport.isOutputRetired else { return }
            self.onSessionRestoreFailed?()
        }
    }
    private func acceptsWeb(_ context: WebPlaybackOutputContext) -> Bool {
        guard activeKind == .web, !isPreparing, webContext == context, let binding = webBinding,
              coordinator.acceptsEvent(binding), webTransport.currentOutputContext == context,
              context.engineInstanceID == web.outputInstanceID, context.loadID == binding.nativeMediaID,
              context.occurrence == binding.permit.scope.occurrence else { return false }
        return isCurrent(binding.permit.scope)
    }
    private func receiveWeb(_ event: WebPlaybackOutputEvent) {
        if case let .failure(message, reason) = event.kind {
            guard activeKind == .web, let permit, permit.isCurrent, isCurrent(permit.scope),
                  webTransport.requestedOutputContext == event.context, event.context.engineInstanceID == web.outputInstanceID,
                  event.context.occurrence == permit.scope.occurrence else { return }
            beginRetirement(); errorMessage = message; failureReason = reason
            playbackIntent = false; isPlaying = false; isBuffering = false; isStartingPlayback = false; isPreparing = false
            onStateChanged?(); onFailure?(); return
        }
        guard acceptsWeb(event.context) else { return }
        let occurrence = event.context.occurrence
        switch event.kind {
        case .state: refreshWeb(notify: true)
        case let .progress(position, duration, ended):
            refreshWeb(notify: false)
            onVerifiedContentProgress?(occurrence, position, duration, ended)
        case .ended: isPlaying = false; isBuffering = false; onEnded?(occurrence)
        case let .rates(snapshot): onEpisodeRates?(occurrence, snapshot)
        case .listeningInterrupted: onListeningInterrupted?(occurrence)
        case .outputInterrupted: onPlaybackOutputInterrupted?(occurrence)
        case .failure: break
        }
    }
    private func refreshWeb(notify: Bool) {
        guard let context = webContext, acceptsWeb(context) else { return }
        if isPlaying != webTransport.isPlaying { isPlaying = webTransport.isPlaying }
        if isBuffering != webTransport.isBuffering { isBuffering = webTransport.isBuffering }
        if isStartingPlayback != webTransport.isStartingPlayback { isStartingPlayback = webTransport.isStartingPlayback }
        if playbackIntent != webTransport.playbackIntent { playbackIntent = webTransport.playbackIntent }
        if errorMessage != webTransport.errorMessage { errorMessage = webTransport.errorMessage }
        if failureReason != webTransport.failureReason { failureReason = webTransport.failureReason }
        if notify { onStateChanged?() }
    }
    private func receiveLocal(_ event: LocalAudioEngineEvent) {
        guard activeKind == .local, let permit, event.binding.permit === permit,
              coordinator.acceptsEvent(event.binding), isCurrent(permit.scope) else { return }
        let changed = isPlaying != event.playing || isBuffering != event.buffering || (!isPreparing && isStartingPlayback)
        let newBinding = lastLocalEventBindingID != event.binding.id
        lastLocalEventBindingID = event.binding.id
        if isPlaying != event.playing { isPlaying = event.playing }
        if isBuffering != event.buffering { isBuffering = event.buffering }
        if !isPreparing, isStartingPlayback { isStartingPlayback = false }
        switch event.kind {
        case .state: if changed || newBinding { onStateChanged?() }
        case .ended:
            isPlaying = false; isBuffering = false; onStateChanged?(); onEnded?(permit.scope.occurrence)
        case let .failed(issue): failLocal(permit.scope, issue: issue)
        }
    }
    private func handle(_ result: Result<Void, LocalAudioPlaybackIssue>, scope: PlaybackOutputScope) {
        if case let .failure(issue) = result { failLocal(scope, issue: issue) }
    }
    private func failLocal(_ scope: PlaybackOutputScope, issue: LocalAudioPlaybackIssue) {
        guard isCurrent(scope) else { return }
        beginRetirement()
        errorMessage = issue.errorDescription; failureReason = .mediaUnavailable
        playbackIntent = false; isPlaying = false; isBuffering = false; isStartingPlayback = false; isPreparing = false
        onStateChanged?(); onFailure?()
    }
    private func failHandoff(_ scope: PlaybackOutputScope) {
        guard isCurrent(scope) else { return }
        beginRetirement()
        errorMessage = AppLocalization.text("Playback could not confirm that the previous player stopped. Try again after playback stops.")
        failureReason = .controlsUnavailable; playbackIntent = false; isPlaying = false; isBuffering = false
        isStartingPlayback = false; isPreparing = false; onStateChanged?(); onFailure?()
    }
}

@MainActor struct LocalAudioPlaybackConfiguration {
    let profileStorageID: UUID
    let prepare: (Track, PlaybackOutputScope, LocalAudioIOAuthorization, TimeInterval) async -> Result<LocalAudioPreparedItem, LocalAudioPlaybackIssue>
    let makeEngine: (@escaping @MainActor (PlaybackOutputPermit, any PlaybackOutputEngine, UUID) -> PlaybackOutputEventBinding?,
                     @escaping @MainActor (PlaybackOutputEventBinding) -> Bool) -> LocalAudioPlayerEngine
}
