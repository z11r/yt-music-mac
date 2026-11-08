import Foundation
import MusicCore

struct EpisodeRateTarget: Equatable, Sendable {
    enum Content: String, Decodable, Sendable { case episode, song }
    let loadID: UUID
    let documentID: UUID
    let occurrence: PlaybackOccurrence
    let mediaGeneration: Int
    let content: Content
    var payload: [String: Any] {
        let identity = PlaybackBridgeIdentity(occurrence)
        return ["loadID": loadID.uuidString.lowercased(), "documentID": documentID.uuidString.lowercased(),
                "identity": ["sessionID": identity.sessionID.uuidString.lowercased(), "entryID": identity.entryID.uuidString.lowercased(),
                             "trackID": identity.trackID, "generation": identity.generation],
                "mediaGeneration": mediaGeneration, "content": content.rawValue]
    }
}

/// Optional malformed rate fields cannot reject a normal playback message.
struct EpisodeRateMedia: Decodable, Equatable, Sendable {
    let rate: Double?
    let changes: Int?
    init(rate: Double, changes: Int) { self.rate = rate; self.changes = changes }
    init(from decoder: any Decoder) throws {
        let container = try? decoder.container(keyedBy: Keys.self)
        let rate = try? container?.decode(Double.self, forKey: .rate)
        let changes = try? container?.decode(Int.self, forKey: .changes)
        if let rate, rate.isFinite, (0.25...4).contains(rate), let changes, (0...Int(Int32.max)).contains(changes) {
            self.rate = rate; self.changes = changes
        } else { self.rate = nil; self.changes = nil }
    }
    private enum Keys: CodingKey { case rate, changes }
}
struct EpisodeRateSnapshot: Decodable, Equatable, Sendable {
    let rates: [Double]
    let current: Double
    let mediaRate: Double
    let changes: Int
    var isValid: Bool {
        !rates.isEmpty && rates.count <= 16 && rates.allSatisfy { $0.isFinite && (0.25...4).contains($0) } &&
            Set(rates).count == rates.count && rates.contains(current) && current == mediaRate && (0...Int(Int32.max)).contains(changes)
    }
}
struct EpisodeRateRequest: Sendable {
    enum Action: String, Sendable { case snapshot, setEpisodeRate, resetOwnedSongRate }
    let target: EpisodeRateTarget
    let revision: Int
    let action: Action
    var rate: Double?
    var expectedRate: Double?
    var expectedChanges: Int?
    var payload: [String: Any] {
        var value = target.payload
        value["revision"] = revision
        if let rate { value["rate"] = rate }
        if let expectedRate { value["expectedRate"] = expectedRate }
        if let expectedChanges { value["expectedChanges"] = expectedChanges }
        return value
    }
}
enum EpisodeRateOutcome: Equatable, Sendable {
    case supported(EpisodeRateSnapshot), confirmed(EpisodeRateSnapshot, changed: Bool)
    case unsupported, rejected, stale, cancelled
}

@MainActor final class EpisodeRateReply {
    private var continuation: CheckedContinuation<EpisodeRateOutcome, Never>?
    private var timeout: Task<Void, Never>?
    private var result: EpisodeRateOutcome?
    func wait(timeout duration: Duration = .seconds(3), start: (@escaping @MainActor (EpisodeRateOutcome) -> Void) -> Void) async -> EpisodeRateOutcome {
        if Task.isCancelled { finish(.cancelled) }
        if let result { return result }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: duration) } catch { return }
                self?.finish(.rejected)
            }
            start { [weak self] in self?.finish($0) }
        }
    }
    func finish(_ outcome: EpisodeRateOutcome) {
        guard result == nil else { return }
        result = outcome; timeout?.cancel(); timeout = nil
        continuation?.resume(returning: outcome); continuation = nil
    }
}

/// Owns only optional rate work. It cannot issue transport, seek, reload, or
/// presentation commands. Capability reads happen once per media/counter pair
/// and on explicit refresh, never on ordinary song progress without ownership.
@MainActor final class EpisodeRateController {
    var execute: (EpisodeRateRequest) async -> EpisodeRateOutcome = { _ in .unsupported }
    var report: (PlaybackOccurrence, EpisodeRateSnapshot?) -> Void = { _, _ in }
    var didFinishSongReset: (EpisodeRateTarget, Bool) -> Void = { _, _ in }
    private var target: EpisodeRateTarget?
    private var media: EpisodeRateMedia?
    private var snapshot: EpisodeRateSnapshot?
    private var owned: (rate: Double, target: EpisodeRateTarget, changes: Int)?
    private var lastProbe: (target: EpisodeRateTarget, changes: Int)?
    private var epoch = UUID()
    private var revision = 0
    private var work: Task<EpisodeRateOutcome, Never>?
    private var probeTask: Task<Void, Never>?
    private var isSetting = false
    var needsSongReset: Bool { owned != nil || (isSetting && target?.content == .song) }

    func prepareLoad(content: EpisodeRateTarget.Content?) {
        invalidate(clearOwnership: content == nil)
    }
    func invalidate(clearOwnership: Bool = true) {
        epoch = UUID(); work?.cancel(); work = nil; probeTask?.cancel(); probeTask = nil; isSetting = false
        if let target, target.content == .episode { report(target.occurrence, nil) }
        target = nil; media = nil; snapshot = nil; lastProbe = nil
        if clearOwnership { owned = nil }
    }
    func accept(_ value: EpisodeRateTarget, media observation: EpisodeRateMedia) {
        guard let rate = observation.rate, rate.isFinite, (0.25...4).contains(rate), let changes = observation.changes, (0...Int(Int32.max)).contains(changes) else {
            invalidate(); return
        }
        if target == value, let previous = media?.changes, changes < previous { return }
        if target != value {
            invalidate(clearOwnership: false)
            target = value
        }
        if let owned, owned.target == value, !isSetting, (owned.rate != rate || owned.changes != changes) { self.owned = nil }
        media = observation
        guard value.content == .episode || owned != nil else { return }
        guard !isSetting, probeTask == nil, work == nil,
              lastProbe?.target != value || lastProbe?.changes != changes else { return }
        lastProbe = (value, changes)
        let expected = epoch
        probeTask = Task { [weak self] in
            guard let self else { return }
            await self.probe(value, epoch: expected)
            if self.epoch == expected { self.probeTask = nil }
        }
    }
    func refresh(occurrence: PlaybackOccurrence) {
        guard let target, target.content == .episode, target.occurrence == occurrence, work == nil, probeTask == nil,
              let media else { return }
        lastProbe = nil
        accept(target, media: media)
    }
    func waitUntilIdle() async { await probeTask?.value; _ = await work?.value }

    func set(_ rate: Double, occurrence: PlaybackOccurrence) async -> Bool {
        guard let target, target.content == .episode, target.occurrence == occurrence,
              let snapshot, snapshot.isValid, snapshot.rates.contains(rate), work == nil, probeTask == nil,
              media?.rate == snapshot.current, media?.changes == snapshot.changes else { return false }
        let expected = epoch
        isSetting = true
        let outcome = await perform(target: target, action: .setEpisodeRate, rate: rate, snapshot: snapshot)
        guard epoch == expected, self.target == target else { return false }
        isSetting = false
        guard case let .confirmed(confirmed, changed) = outcome, valid(confirmed, target: target), confirmed.current == rate else {
            self.snapshot = nil; owned = nil; report(occurrence, nil); return false
        }
        self.snapshot = confirmed; media = .init(rate: confirmed.current, changes: confirmed.changes)
        lastProbe = (target, confirmed.changes)
        if changed { owned = rate == 1 ? nil : (rate, target, confirmed.changes) }
        report(occurrence, confirmed)
        return true
    }

    private func probe(_ target: EpisodeRateTarget, epoch expected: UUID) async {
        guard epoch == expected, self.target == target, !Task.isCancelled else { return }
        let outcome = await perform(target: target, action: .snapshot)
        guard epoch == expected, self.target == target else { return }
        guard case let .supported(value) = outcome, valid(value, target: target) else {
            snapshot = nil; owned = nil
            if target.content == .episode { report(target.occurrence, nil) }
            else { didFinishSongReset(target, false) }
            return
        }
        snapshot = value; media = .init(rate: value.current, changes: value.changes); lastProbe = (target, value.changes)
        if let owned, owned.rate != value.current || (owned.target == target && owned.changes != value.changes) { self.owned = nil }
        if target.content == .episode { report(target.occurrence, value); return }
        guard let inherited = owned, inherited.rate == value.current, value.rates.contains(1) else {
            owned = nil; didFinishSongReset(target, false); return
        }
        // Consume ownership before sending: a replaced media element cannot
        // replay an already attempted reset whose outcome is unknown.
        owned = nil
        isSetting = true
        let reset = await perform(target: target, action: .resetOwnedSongRate, rate: 1, snapshot: value)
        guard epoch == expected, self.target == target else { return }
        let confirmed: Bool
        if case let .confirmed(actual, _) = reset { confirmed = valid(actual, target: target) && actual.current == 1 }
        else { confirmed = false }
        isSetting = false; owned = nil; snapshot = nil
        didFinishSongReset(target, confirmed)
    }
    private func valid(_ value: EpisodeRateSnapshot, target: EpisodeRateTarget) -> Bool {
        value.isValid && (media?.changes.map { value.changes >= $0 } ?? false)
    }
    private func perform(target: EpisodeRateTarget, action: EpisodeRateRequest.Action,
                         rate: Double? = nil, snapshot: EpisodeRateSnapshot? = nil) async -> EpisodeRateOutcome {
        guard self.target == target, !Task.isCancelled, work == nil else { return .stale }
        guard revision < Int(Int32.max) else { return .unsupported }
        revision += 1
        let request = EpisodeRateRequest(target: target, revision: revision, action: action, rate: rate,
                                         expectedRate: snapshot?.current, expectedChanges: snapshot?.changes)
        let expected = epoch
        let execute = self.execute
        let task = Task { await execute(request) }
        work = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if epoch == expected, self.target == target { work = nil }
        guard epoch == expected, self.target == target, !Task.isCancelled else { return .stale }
        return result
    }
}

struct EpisodeRateResponse: Decodable {
    let accepted: Bool
    let reason: String
    let changed: Bool
    let snapshot: EpisodeRateSnapshot?
    let loadID: UUID
    let documentID: UUID
    let identity: PlaybackBridgeIdentity
    let mediaGeneration: Int
    let content: EpisodeRateTarget.Content
    static func decode(_ body: Any, request: EpisodeRateRequest) -> EpisodeRateOutcome {
        guard JSONSerialization.isValidJSONObject(body), let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 8_192,
              let reply = try? JSONDecoder().decode(Self.self, from: data), reply.loadID == request.target.loadID,
              reply.documentID == request.target.documentID, reply.identity == PlaybackBridgeIdentity(request.target.occurrence),
              reply.mediaGeneration == request.target.mediaGeneration, reply.content == request.target.content else { return .stale }
        if reply.reason == "unsupported" { return .unsupported }
        if reply.reason == "stale" { return .stale }
        guard let snapshot = reply.snapshot, snapshot.isValid else { return .rejected }
        if reply.reason == "supported", !reply.accepted, !reply.changed, request.action == .snapshot { return .supported(snapshot) }
        if reply.reason == "confirmed", reply.accepted, request.action != .snapshot, snapshot.current == request.rate,
           reply.changed == (request.expectedRate != snapshot.current) {
            return .confirmed(snapshot, changed: reply.changed)
        }
        return .rejected
    }
}
