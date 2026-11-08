import Foundation
import MusicCore
import Testing
import WebKit
@testable import YTMusicMac

@MainActor private final class EpisodeRateHarness {
    let controller = EpisodeRateController()
    var requests: [EpisodeRateRequest] = []
    var reports: [EpisodeRateSnapshot?] = []
    var retired: [Bool] = []
    var current = 1.0
    var changes = 0
    var rates = [0.75, 1, 1.5, 2]
    var nextMutation: EpisodeRateOutcome?
    var holdMutation = false
    var held: CheckedContinuation<EpisodeRateOutcome, Never>?
    init() {
        controller.execute = { [weak self] request in
            guard let self else { return .cancelled }
            requests.append(request)
            if request.action == .snapshot { return .supported(snapshot()) }
            if holdMutation { return await withCheckedContinuation { held = $0 } }
            if let nextMutation { self.nextMutation = nil; return nextMutation }
            let changed = current != request.rate
            if changed { changes += 1 }
            current = request.rate!
            return .confirmed(snapshot(), changed: changed)
        }
        controller.report = { [weak self] _, snapshot in self?.reports.append(snapshot) }
        controller.didFinishSongReset = { [weak self] _, confirmed in self?.retired.append(confirmed) }
    }
    func snapshot() -> EpisodeRateSnapshot { .init(rates: rates, current: current, mediaRate: current, changes: changes) }
    func observe(_ target: EpisodeRateTarget) { controller.accept(target, media: .init(rate: current, changes: changes)) }
    func release(_ outcome: EpisodeRateOutcome) { held?.resume(returning: outcome); held = nil }
}
private func rateTarget(_ content: EpisodeRateTarget.Content = .episode, media: Int = 1) -> EpisodeRateTarget {
    .init(loadID: UUID(), documentID: UUID(), occurrence: .init(sessionID: UUID(), entryID: UUID(), trackID: "fixture", generation: UInt64.max), mediaGeneration: media, content: content)
}

@MainActor @Suite("Episode rate ownership and scope")
struct EpisodeRateControllerTests {
    @Test func oneProbePerAcceptedMediaAndRateCounterPlusExplicitRefresh() async {
        let h = EpisodeRateHarness(), target = rateTarget()
        for _ in 0..<100 { h.observe(target) }
        await h.controller.waitUntilIdle()
        #expect(h.requests.count == 1 && h.reports.last??.rates == h.rates)
        for _ in 0..<100 { h.observe(target) }
        await h.controller.waitUntilIdle()
        #expect(h.requests.count == 1)
        h.controller.refresh(occurrence: target.occurrence); await h.controller.waitUntilIdle()
        #expect(h.requests.count == 2)
        h.changes = 1; h.observe(target); await h.controller.waitUntilIdle()
        #expect(h.requests.count == 3)
        let ordinary = EpisodeRateHarness()
        ordinary.observe(rateTarget(.song)); await ordinary.controller.waitUntilIdle()
        #expect(ordinary.requests.isEmpty && ordinary.retired.isEmpty)
    }

    @Test func invalidationBeforeTheProbeStartsDoesNoWork() async {
        let h = EpisodeRateHarness()
        h.observe(rateTarget())
        h.controller.invalidate()
        await Task.yield(); await h.controller.waitUntilIdle()
        #expect(h.requests.isEmpty && !h.controller.needsSongReset)
    }

    @Test func onlyAConfirmedActualAppChangeCanOwnAnInheritedRate() async {
        let h = EpisodeRateHarness(), episode = rateTarget()
        h.observe(episode); await h.controller.waitUntilIdle()
        #expect(await h.controller.set(1.5, occurrence: episode.occurrence))
        #expect(h.controller.needsSongReset)
        h.controller.prepareLoad(content: .song)
        let song = rateTarget(.song); h.observe(song); await h.controller.waitUntilIdle()
        #expect(h.requests.map(\.action) == [.snapshot, .setEpisodeRate, .snapshot, .resetOwnedSongRate])
        #expect(h.current == 1 && h.retired == [true] && !h.controller.needsSongReset)
        let count = h.requests.count
        for _ in 0..<100 { h.observe(song) }
        await h.controller.waitUntilIdle()
        #expect(h.requests.count == count)
        #expect(h.requests.last?.expectedRate == 1.5 && h.requests.last?.rate == 1)
    }

    @Test func interveningRateChangesDuringASetDoNotGrantOrRetainOwnership() async {
        for alreadyOwned in [false, true] {
            let h = EpisodeRateHarness(), episode = rateTarget()
            h.observe(episode); await h.controller.waitUntilIdle()
            if alreadyOwned { #expect(await h.controller.set(1.5, occurrence: episode.occurrence)) }
            h.nextMutation = .confirmed(.init(rates: h.rates, current: 1.5, mediaRate: 1.5, changes: 3), changed: !alreadyOwned)
            #expect(await h.controller.set(1.5, occurrence: episode.occurrence))
            #expect(!h.controller.needsSongReset)
            h.current = 1.5; h.changes = 3
            h.controller.prepareLoad(content: .song); h.observe(rateTarget(.song)); await h.controller.waitUntilIdle()
            #expect(!h.requests.contains { $0.action == .resetOwnedSongRate })
            #expect(h.current == 1.5)
        }
    }

    @Test func anAlreadySelectedPageRateIsNeverClaimedOrReset() async {
        let h = EpisodeRateHarness(), episode = rateTarget()
        h.current = 1.5; h.observe(episode); await h.controller.waitUntilIdle()
        #expect(await h.controller.set(1.5, occurrence: episode.occurrence))
        #expect(!h.controller.needsSongReset)
        h.controller.prepareLoad(content: .song); h.observe(rateTarget(.song)); await h.controller.waitUntilIdle()
        #expect(h.requests.map(\.action) == [.snapshot, .setEpisodeRate])
        #expect(h.current == 1.5)
    }

    @Test func pageChangesIncludingChangedBackValuesClearOwnership() async {
        let h = EpisodeRateHarness(), episode = rateTarget()
        h.observe(episode); await h.controller.waitUntilIdle()
        #expect(await h.controller.set(1.5, occurrence: episode.occurrence))
        h.controller.accept(episode, media: .init(rate: 1, changes: 0))
        #expect(h.controller.needsSongReset)
        h.changes += 2; h.observe(episode); await h.controller.waitUntilIdle()
        #expect(!h.controller.needsSongReset)
        h.controller.prepareLoad(content: .song); h.observe(rateTarget(.song)); await h.controller.waitUntilIdle()
        #expect(!h.requests.contains { $0.action == .resetOwnedSongRate })
    }

    @Test func differentInheritedRateUnsupportedNormalRateAndUnknownContentNeverReset() async {
        for scenario in 0..<3 {
            let h = EpisodeRateHarness(), episode = rateTarget()
            h.observe(episode); await h.controller.waitUntilIdle()
            #expect(await h.controller.set(1.5, occurrence: episode.occurrence))
            if scenario == 0 { h.current = 2 }
            if scenario == 1 { h.rates = [1.5, 2] }
            h.controller.prepareLoad(content: scenario == 2 ? nil : .song)
            h.observe(rateTarget(.song)); await h.controller.waitUntilIdle()
            #expect(!h.requests.contains { $0.action == .resetOwnedSongRate })
            #expect(!h.controller.needsSongReset)
        }
    }

    @Test func refusedResetIsAttemptedOnceAndNeverReportedAsConfirmed() async {
        let h = EpisodeRateHarness(), episode = rateTarget()
        h.observe(episode); await h.controller.waitUntilIdle()
        #expect(await h.controller.set(1.5, occurrence: episode.occurrence))
        h.nextMutation = .rejected
        h.controller.prepareLoad(content: .song)
        let song = rateTarget(.song); h.observe(song); await h.controller.waitUntilIdle()
        #expect(h.retired == [false] && !h.controller.needsSongReset && h.current == 1.5)
        for _ in 0..<50 { h.observe(song) }
        await h.controller.waitUntilIdle()
        #expect(h.requests.filter { $0.action == .resetOwnedSongRate }.count == 1)
    }

    @Test func replacingMediaDuringAnAttemptCannotReplayAnUncertainSongReset() async throws {
        let h = EpisodeRateHarness(), episode = rateTarget()
        h.observe(episode); await h.controller.waitUntilIdle()
        #expect(await h.controller.set(1.5, occurrence: episode.occurrence))
        h.controller.prepareLoad(content: .song); h.holdMutation = true
        h.observe(rateTarget(.song))
        for _ in 0..<100 where h.held == nil { await Task.yield() }
        _ = try #require(h.held)
        #expect(h.controller.needsSongReset)
        h.controller.prepareLoad(content: .song)
        h.observe(rateTarget(.song, media: 2))
        h.release(.confirmed(.init(rates: h.rates, current: 1, mediaRate: 1, changes: 1), changed: true))
        for _ in 0..<10 { await Task.yield() }
        await h.controller.waitUntilIdle()
        #expect(h.requests.filter { $0.action == .resetOwnedSongRate }.count == 1)
        #expect(!h.controller.needsSongReset)
    }

    @Test func staleOccurrenceUnsupportedRatesAndUnconfirmedReadbackNeverGrantOwnership() async {
        let h = EpisodeRateHarness(), episode = rateTarget()
        h.observe(episode); await h.controller.waitUntilIdle()
        #expect(await !h.controller.set(1.5, occurrence: rateTarget().occurrence))
        #expect(await !h.controller.set(3, occurrence: episode.occurrence))
        h.nextMutation = .confirmed(.init(rates: h.rates, current: 1.5, mediaRate: 1, changes: 1), changed: true)
        #expect(await !h.controller.set(1.5, occurrence: episode.occurrence))
        #expect(!h.controller.needsSongReset)
    }

    @Test func invalidatingAnAccountOrReplacingMediaFencesAnOutstandingConfirmation() async throws {
        for accountChange in [false, true] {
            let h = EpisodeRateHarness(), episode = rateTarget()
            h.observe(episode); await h.controller.waitUntilIdle()
            h.holdMutation = true
            let change = Task { await h.controller.set(1.5, occurrence: episode.occurrence) }
            for _ in 0..<100 where h.held == nil { await Task.yield() }
            _ = try #require(h.held)
            if accountChange { h.controller.invalidate() }
            else { h.controller.prepareLoad(content: .episode); h.observe(rateTarget(media: 2)) }
            h.release(.confirmed(.init(rates: h.rates, current: 1.5, mediaRate: 1.5, changes: 1), changed: true))
            #expect(await !change.value)
            await h.controller.waitUntilIdle()
            #expect(!h.controller.needsSongReset)
        }
    }

    @Test func cancelledOptionalWorkCannotClaimAConfirmedRate() async throws {
        let h = EpisodeRateHarness(), episode = rateTarget()
        h.observe(episode); await h.controller.waitUntilIdle()
        h.holdMutation = true
        let change = Task { await h.controller.set(1.5, occurrence: episode.occurrence) }
        for _ in 0..<100 where h.held == nil { await Task.yield() }
        _ = try #require(h.held)
        change.cancel()
        h.release(.confirmed(.init(rates: h.rates, current: 1.5, mediaRate: 1.5, changes: 1), changed: true))
        #expect(await !change.value)
        #expect(!h.controller.needsSongReset)
        h.holdMutation = false
        h.controller.refresh(occurrence: episode.occurrence); await h.controller.waitUntilIdle()
        #expect(h.requests.filter { $0.action == .snapshot }.count == 2)
    }

    @Test func repliesAreBoundedSingleCompletionAndStrictlyScopeDecoded() async throws {
        let target = rateTarget(), snapshot = EpisodeRateSnapshot(rates: [1, 1.5], current: 1.5, mediaRate: 1.5, changes: 1)
        let reply = EpisodeRateReply()
        #expect(await reply.wait { finish in finish(.confirmed(snapshot, changed: true)); finish(.rejected) } == .confirmed(snapshot, changed: true))
        let timeout = EpisodeRateReply()
        #expect(await timeout.wait(timeout: .milliseconds(1), start: { _ in }) == .rejected)
        let request = EpisodeRateRequest(target: target, revision: 1, action: .setEpisodeRate, rate: 1.5, expectedRate: 1, expectedChanges: 0)
        var body = target.payload
        body["accepted"] = true; body["reason"] = "confirmed"; body["changed"] = true
        body["snapshot"] = ["rates": [1, 1.5], "current": 1.5, "mediaRate": 1.5, "changes": 1]
        #expect(EpisodeRateResponse.decode(body, request: request) == .confirmed(snapshot, changed: true))
        body["changed"] = false
        #expect(EpisodeRateResponse.decode(body, request: request) == .rejected)
        body["changed"] = true
        body["documentID"] = UUID().uuidString
        #expect(EpisodeRateResponse.decode(body, request: request) == .stale)
        body["documentID"] = target.documentID.uuidString
        body["snapshot"] = ["rates": [1, 1.5], "current": 1.5, "mediaRate": 1, "changes": 1]
        #expect(EpisodeRateResponse.decode(body, request: request) == .rejected)
    }

    @Test func malformedOptionalRateDataDoesNotRejectOrdinaryPlayback() throws {
        let target = rateTarget()
        var body = target.payload
        body.merge(["kind": "progress", "sequence": 1, "commandRevision": 0, "playbackIntent": true, "intentSource": "native",
            "videoID": target.occurrence.trackID, "position": 42, "duration": 180, "volume": 0.5,
            "isPlaying": true, "isBuffering": false, "isAd": false, "mediaReady": true,
            "episodeRateMedia": ["rate": "1.5", "changes": true]] as [String: Any]) { _, value in value }
        let message = try #require(PlaybackBridgeMessage.decode(body))
        #expect(message.confirmsContentPlayback && message.episodeRateMedia?.rate == nil)
    }

    @Test func theOptionalServiceAdapterIsMainFrameOnlyAndDoesNotLoadAPage() {
        let player = WebPlayer(dataStore: .nonPersistent())
        let scripts = player.webView.configuration.userContentController.userScripts
        let service = scripts.filter { $0.source.contains("YTMusicNativeEpisodeRateV1") }
        #expect(service.count == 1 && service[0].isForMainFrameOnly && scripts.count == 2)
        #expect(player.webView.url == nil && !player.webView.isLoading && !player.episodeRates.needsSongReset)
        #expect(player.errorMessage == nil)
    }
}
