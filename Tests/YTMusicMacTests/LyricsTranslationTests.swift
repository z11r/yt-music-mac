import Foundation
import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

@MainActor @Suite("Explicit Apple lyrics translation boundaries")
struct LyricsTranslationTests {
    @Test func sourceBoundsPreserveOriginalTimedAndPlainTextWithoutTimingInference() throws {
        let id = UUID(), text = "First line\nSecond line"
        let plain = MusicLyrics.plain(text: text, source: "Original provider")
        let timed = MusicLyrics.timed(lines: [.init(startTime: 1, duration: 2, text: "First line"), .init(startTime: 4, text: "Second line")], source: "Original provider")
        #expect(LyricsTranslationSource.capture(requestID: id, videoID: "abcDEF12_-3", lyrics: plain)?.text == text)
        #expect(LyricsTranslationSource.capture(requestID: id, videoID: "abcDEF12_-3", lyrics: timed)?.text == text)
        #expect(timed.activeLineIndex(at: 2) == 0 && timed.source == "Original provider" && timed.text == text)
        for value in ["", "   \n", "a\0b", String(repeating: "é", count: 8_193), String(repeating: "x\n", count: 500)] {
            #expect(LyricsTranslationSource.capture(requestID: id, videoID: "abcDEF12_-3", lyrics: .plain(text: value, source: nil)) == nil)
        }
        #expect(LyricsTranslationSource.capture(requestID: id, videoID: "bad", lyrics: plain) == nil)
        #expect(LyricsTranslationSource.capture(requestID: id, videoID: "abcDEF12_-3", lyrics: .unavailable) == nil)
        let multiline = MusicLyrics.timed(lines: [.init(startTime: 1, text: String(repeating: "x\n", count: 500))], source: nil)
        #expect(LyricsTranslationSource.capture(requestID: id, videoID: "abcDEF12_-3", lyrics: multiline) == nil)
        #expect(LyricsTranslationSource.capture(requestID: id, videoID: "abcDEF12_-3", lyrics: .plain(text: String(repeating: "a", count: 16_384), source: nil)) != nil)
    }
    @Test func originalProviderCreditIsFrozenVerbatimBoundedAndNeverPartOfTranslationInput() async throws {
        let id = UUID(), credit = "  Original 100% %@ \u{202e}credit\u{202c}\nsecond line  "
        let plain = try #require(LyricsTranslationSource.capture(requestID: id, videoID: "abcDEF12_-3", lyrics: .plain(text: "Words", source: credit)))
        let timed = try #require(LyricsTranslationSource.capture(requestID: id, videoID: "abcDEF12_-3", lyrics: .timed(lines: [.init(startTime: 1, text: "Words")], source: credit)))
        #expect(plain.originalProvider == credit && timed.originalProvider == credit && plain == timed)
        let absent = try #require(LyricsTranslationSource.capture(requestID: id, videoID: "abcDEF12_-3", lyrics: .plain(text: "Words", source: nil)))
        let changed = try #require(LyricsTranslationSource.capture(requestID: id, videoID: "abcDEF12_-3", lyrics: .plain(text: "Words", source: "Changed credit")))
        #expect(absent.originalProvider == nil && plain != absent && plain != changed)
        for footer in [String(repeating: "x", count: 4_097), String(repeating: "😀", count: 4_097), "bad\0credit"] {
            #expect(LyricsTranslationSource.capture(requestID: id, videoID: "abcDEF12_-3", lyrics: .plain(text: "Words", source: footer)) == nil)
        }
        let target = LyricsTranslationTarget(id: UUID(), profile: UUID(), account: UUID(), entry: UUID(), occurrence: nil, source: plain)
        #expect(!target.matches(profile: target.profile, account: target.account, entry: target.entry, occurrence: nil, source: changed))
        let controller = LyricsTranslationController(admission: LyricsTranslationAdmission()), provider = TranslationProvider()
        controller.open(target, isCurrent: { true })
        controller.loadLanguages(for: target) { [.init(id: "en", name: "English"), .init(id: "fr", name: "French")] }; await controller.waitForIdle()
        let job = try #require(controller.begin(for: target, pair: .init(source: "en", target: "fr")))
        await controller.run(job, using: provider)
        #expect(provider.texts == ["Words"] && !provider.texts.contains(credit))
    }
    @Test func appearanceLanguageSelectionAndMissingOrUnsupportedChoicesNeverTranslate() async throws {
        let f = TranslationFixture(); #expect(!f.controller.isBusy && f.provider.calls.isEmpty)
        #expect(f.controller.begin(for: f.target, pair: f.pair) == nil)
        await f.loadLanguages()
        f.controller.cancel(f.target.id) // A picker change only resets idle/result state.
        #expect(f.controller.state == .idle && f.provider.calls.isEmpty && !f.controller.isBusy)
        #expect(f.controller.begin(for: f.target, pair: .init(source: "en", target: "en")) == nil)
        #expect(f.controller.begin(for: f.target, pair: .init(source: "unknown", target: "fr")) == nil)
        #expect(f.provider.calls.isEmpty && !f.controller.isBusy)
        let job = try #require(f.controller.begin(for: f.target, pair: f.pair)); #expect(f.provider.calls.isEmpty)
        f.controller.cancel()
        await f.controller.run(job, using: f.provider)
        #expect(f.provider.calls.isEmpty && !f.controller.isBusy)
    }
    @Test func validExplicitJobPreparesThenPassesOnlyFrozenLyricTextAndPublishesUntimedOutput() async throws {
        let f = TranslationFixture(); await f.loadLanguages()
        let job = try #require(f.controller.begin(for: f.target, pair: f.pair))
        await f.controller.run(job, using: f.provider)
        #expect(f.provider.calls == ["support", "prepare", "translate"])
        #expect(f.provider.texts == [f.target.source.text])
        #expect(f.controller.state == .available("Synthetic translation") && !f.controller.isBusy)
    }
    @Test func ownerOrSourceRevocationDuringHeldPreparationPassesZeroTextAndRetainsTheSlot() async throws {
        for changed in [true, false] {
            let f = TranslationFixture(); await f.loadLanguages(); f.provider.held = .prepare
            let job = try #require(f.controller.begin(for: f.target, pair: f.pair))
            let task = Task { await f.controller.run(job, using: f.provider) }
            await f.provider.wait(.prepare)
            if changed { f.owner.current = false } else { f.controller.cancel() }
            #expect(f.controller.isBusy && f.provider.texts.isEmpty)
            let other = LyricsTranslationController(admission: f.admission)
            other.open(f.target, isCurrent: { true }); other.loadLanguages(for: f.target) { Issue.record("second language read"); return [] }
            #expect(other.isBusy)
            f.provider.release()
            await task.value
            #expect(f.provider.texts.isEmpty && !f.controller.isBusy)
            #expect(changed ? f.controller.state == .idle : f.controller.state == .canceled)
        }
    }
    @Test func stalePendingConfigurationCannotStartNativeWorkOrStrandAdmission() async throws {
        let f = TranslationFixture(); await f.loadLanguages()
        let job = try #require(f.controller.begin(for: f.target, pair: f.pair))
        f.owner.current = false
        await f.controller.run(job, using: f.provider)
        #expect(f.provider.calls.isEmpty && !f.controller.isBusy && f.controller.state == .idle)
    }
    @Test func languageChangeAndReplacedJobCannotRelabelAnOldConfigurationOrResult() async throws {
        let f = TranslationFixture(); await f.loadLanguages()
        let old = try #require(f.controller.begin(for: f.target, pair: f.pair)); f.controller.cancel()
        let new = try #require(f.controller.begin(for: f.target, pair: .init(source: "fr", target: "en")))
        await f.controller.run(old, using: f.provider)
        #expect(f.provider.calls.isEmpty && f.controller.isBusy)
        f.provider.response = .init(text: "New translation", sourceLanguage: "fr", targetLanguage: "en")
        await f.controller.run(new, using: f.provider)
        #expect(f.controller.state == .available("New translation") && f.provider.texts.count == 1)
    }
    @Test func canceledHeldTranslationCannotPublishAndAClosedOldPresentationCannotClearANewOne() async throws {
        let f = TranslationFixture(); await f.loadLanguages(); f.provider.held = .translate
        let job = try #require(f.controller.begin(for: f.target, pair: f.pair))
        let task = Task { await f.controller.run(job, using: f.provider) }; await f.provider.wait(.translate)
        f.controller.close(f.target.id)
        #expect(f.controller.state == .idle && f.controller.isBusy)
        let replacement = translationTarget()
        f.controller.open(replacement, isCurrent: { true }); f.controller.close(f.target.id)
        #expect(f.controller.target == replacement && f.controller.isBusy)
        f.provider.release(); await task.value
        #expect(f.controller.target == replacement && f.controller.state == .idle && !f.controller.isBusy)
    }
    @Test func pairSupportIsRecheckedBeforeAnyPreparationAndUnsupportedPairsPassNoText() async throws {
        let f = TranslationFixture(); await f.loadLanguages(); f.provider.supported = false
        let job = try #require(f.controller.begin(for: f.target, pair: f.pair)); await f.controller.run(job, using: f.provider)
        #expect(f.provider.calls == ["support"] && f.provider.texts.isEmpty && f.controller.state == .unavailable)
    }
    @Test func ownerRevocationWhilePairReadIsHeldNeverPreparesOrPassesText() async throws {
        let f = TranslationFixture(); await f.loadLanguages(); f.provider.held = .support
        let job = try #require(f.controller.begin(for: f.target, pair: f.pair))
        let task = Task { await f.controller.run(job, using: f.provider) }; await f.provider.wait(.support)
        f.owner.current = false; f.provider.release(); await task.value
        #expect(f.provider.calls == ["support"] && f.provider.texts.isEmpty && !f.controller.isBusy)
    }
    @Test func oversizedEmptyContradictoryAndControlOutputNeverPublishes() async throws {
        for response in [LyricsTranslationResponse(text: String(repeating: "é", count: 32_769), sourceLanguage: "en", targetLanguage: "fr"),
                         .init(text: " ", sourceLanguage: "en", targetLanguage: "fr"), .init(text: "a\0b", sourceLanguage: "en", targetLanguage: "fr"),
                         .init(text: "Wrong language", sourceLanguage: "de", targetLanguage: "fr"), .init(text: "Wrong target", sourceLanguage: "en", targetLanguage: "de")] {
            let f = TranslationFixture(); await f.loadLanguages(); f.provider.response = response
            let job = try #require(f.controller.begin(for: f.target, pair: f.pair)); await f.controller.run(job, using: f.provider)
            #expect(f.controller.state == .unavailable && !f.controller.isBusy)
        }
    }
    @Test func staleLanguageLoadAndMalformedCatalogCannotCreateTranslationChoices() async {
        for values in [[LyricsTranslationLanguage](), [.init(id: "en", name: "English"), .init(id: "en", name: "Duplicate")],
                       [.init(id: String(repeating: "x", count: 129), name: "Too long")]] {
            let f = TranslationFixture(); f.controller.loadLanguages(for: f.target) { values }; await f.controller.waitForIdle()
            #expect(f.controller.languages.isEmpty && f.controller.state == .unavailable && !f.controller.isBusy)
        }
        let f = TranslationFixture(), gate = TranslationLanguageGate()
        f.controller.loadLanguages(for: f.target) { await gate.wait() }; await gate.started()
        f.controller.clear(); #expect(f.controller.isBusy)
        await gate.release(); await f.controller.waitForIdle()
        #expect(f.controller.languages.isEmpty && f.controller.state == .idle && !f.controller.isBusy)
    }
    @Test func sourceSnapshotNonceRejectsReopenedIdenticalLyricsWithoutNativeAPIs() async throws {
        let lyrics = LyricsSession { _ in .plain(text: "Synthetic words", source: "Original") }
        lyrics.load(videoID: "abcDEF12_-3"); await lyrics.task?.value
        let old = try #require(lyrics.translationSource)
        lyrics.clear(); lyrics.load(videoID: old.videoID); await lyrics.task?.value
        #expect(!lyrics.acceptsTranslationSource(old))
        let fresh = try #require(lyrics.translationSource)
        #expect(fresh.text == old.text && fresh.videoID == old.videoID && fresh.requestID != old.requestID)
    }
    @Test func everyProfileAccountEntryOccurrenceAndSourceChangeRejectsTheFrozenTarget() throws {
        let original = translationTarget(), occurrence = PlaybackOccurrence(sessionID: UUID(), entryID: original.entry, trackID: original.source.videoID, generation: 1)
        let target = LyricsTranslationTarget(id: original.id, profile: original.profile, account: original.account, entry: original.entry,
            occurrence: occurrence, source: original.source)
        #expect(target.matches(profile: target.profile, account: target.account, entry: target.entry, occurrence: occurrence, source: target.source))
        for field in 0..<5 {
            let changed = try #require(LyricsTranslationSource.capture(requestID: UUID(), videoID: target.source.videoID, lyrics: .plain(text: target.source.text, source: nil)))
            #expect(!target.matches(profile: field == 0 ? UUID() : target.profile, account: field == 1 ? UUID() : target.account,
                entry: field == 2 ? UUID() : target.entry, occurrence: field == 3 ? nil : occurrence, source: field == 4 ? changed : target.source))
        }
    }
    @Test func oldPresentationActionsCannotBorrowAReopenedOwnerOrCancelItsReservedJob() async throws {
        let f = TranslationFixture(); await f.loadLanguages()
        let replacement = translationTarget(); f.controller.open(replacement, isCurrent: { true })
        f.controller.loadLanguages(for: f.target) { Issue.record("old view loaded languages"); return [] }
        #expect(f.controller.begin(for: f.target, pair: f.pair) == nil)
        f.controller.loadLanguages(for: replacement) { [.init(id: "en", name: "English"), .init(id: "fr", name: "French")] }
        await f.controller.waitForIdle()
        let job = try #require(f.controller.begin(for: replacement, pair: f.pair))
        f.controller.cancel(f.target.id); f.controller.close(f.target.id)
        #expect(f.controller.target == replacement && f.controller.isBusy)
        await f.controller.run(job, using: f.provider)
        #expect(f.controller.state == .available("Synthetic translation"))
    }
    @Test func exactHostDisappearanceAfterHeldSupportPreventsEveryLaterSessionCall() async throws {
        let f = TranslationFixture(); await f.loadLanguages(); f.provider.held = .support
        let job = try #require(f.controller.begin(for: f.target, pair: f.pair))
        let task = Task { await f.controller.run(job, using: f.provider) }; await f.provider.wait(.support)
        f.provider.lifetime.revoke(); f.provider.release(); await task.value
        #expect(f.provider.calls == ["support"] && f.provider.texts.isEmpty && f.controller.state == .canceled && !f.controller.isBusy)
    }
    @Test func suppliedTaskCancellationIsVisibleImmediatelyAfterHeldPreparationWithoutAnActorHop() async throws {
        let f = TranslationFixture(); await f.loadLanguages(); f.provider.held = .prepare
        let job = try #require(f.controller.begin(for: f.target, pair: f.pair))
        let task = Task {
            await withLyricsTranslationHostLifetime(f.provider.lifetime) { await f.controller.run(job, using: f.provider) }
        }
        await f.provider.wait(.prepare)
        task.cancel(); #expect(f.controller.isBusy)
        // No yield/actor hop is allowed between cancellation and host revocation.
        #expect(throws: CancellationError.self) { try f.provider.lifetime.check() }
        f.provider.release(); await task.value
        #expect(f.provider.calls == ["support", "prepare"] && f.provider.texts.isEmpty && !f.controller.isBusy && f.controller.state == .canceled)
    }
    @Test func hostRevocationDuringHeldTranslationDropsItsResultEvenWhenTheOwnerIsStillCurrent() async throws {
        let f = TranslationFixture(); await f.loadLanguages(); f.provider.held = .translate
        let job = try #require(f.controller.begin(for: f.target, pair: f.pair))
        let task = Task { await f.controller.run(job, using: f.provider) }; await f.provider.wait(.translate)
        #expect(f.controller.target == f.target && f.provider.texts == [f.target.source.text])
        f.provider.lifetime.revoke(); #expect(f.controller.isBusy)
        f.provider.release(); await task.value
        #expect(f.controller.target == f.target && f.controller.state == .canceled && !f.controller.isBusy)
    }
    @Test func retiredHostCannotBecomeValidAgainOrRevokeAReplacementHost() throws {
        let old = LyricsTranslationHostLifetime(), replacement = LyricsTranslationHostLifetime()
        old.revoke(); old.revoke()
        #expect(throws: CancellationError.self) { try old.check() }
        try replacement.check()
    }
    @Test func englishAndFrenchCopyStayCompleteAndContainDownloadAndPrivacyDisclosure() throws {
        var keys: [Set<String>] = []
        for language in ["en", "fr"] {
            let directory = try #require(AppLocalization.bundle.url(forResource: language, withExtension: "lproj"))
            let bundle = try #require(Bundle(url: directory)), url = try #require(bundle.url(forResource: "LyricsTranslation", withExtension: "strings"))
            let values = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
            #expect(values.count == 22 && values.values.allSatisfy { !$0.isEmpty })
            #expect(values.keys.contains(where: { $0.contains("app identifier") && $0.contains("downloads can continue") }))
            keys.append(Set(values.keys))
        }
        #expect(keys[0] == keys[1])
    }
}
@MainActor private final class TranslationFixture {
    let admission = LyricsTranslationAdmission(), owner = TranslationOwner(), target = translationTarget()
    let provider = TranslationProvider()
    let pair = LyricsTranslationPair(source: "en", target: "fr")
    let controller: LyricsTranslationController
    init() { controller = LyricsTranslationController(admission: admission); controller.open(target) { [owner] in owner.current } }
    func loadLanguages() async { controller.loadLanguages(for: target) { [.init(id: "en", name: "English"), .init(id: "fr", name: "French")] }; await controller.waitForIdle() }
}
@MainActor private final class TranslationOwner { var current = true }
private func translationTarget() -> LyricsTranslationTarget {
    .init(id: UUID(), profile: UUID(), account: UUID(), entry: UUID(), occurrence: nil,
          source: .capture(requestID: UUID(), videoID: "abcDEF12_-3", lyrics: .plain(text: "Synthetic words", source: "Original"))!)
}
@MainActor private final class TranslationProvider: LyricsTranslating {
    enum Stage { case support, prepare, translate }
    var held: Stage?
    var supported = true
    let lifetime = LyricsTranslationHostLifetime()
    var response = LyricsTranslationResponse(text: "Synthetic translation", sourceLanguage: "en", targetLanguage: "fr")
    private(set) var calls: [String] = [], texts: [String] = []
    private var waiting: Stage?
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func supportsPair() async throws -> Bool { try lifetime.check(); calls.append("support"); await pause(.support); try lifetime.check(); return supported }
    func prepare() async throws { try lifetime.check(); calls.append("prepare"); await pause(.prepare); try lifetime.check() }
    func translate(_ text: String) async throws -> LyricsTranslationResponse { try lifetime.check(); calls.append("translate"); texts.append(text); await pause(.translate); try lifetime.check(); return response }
    private func pause(_ stage: Stage) async {
        guard held == stage else { return }
        await withCheckedContinuation { continuation = $0; waiting = stage; let old = observers; observers = []; old.forEach { $0.resume() } }
    }
    func wait(_ stage: Stage) async { if waiting != stage { await withCheckedContinuation { observers.append($0) } } }
    func release() { let old = continuation; continuation = nil; waiting = nil; old?.resume() }
}
private actor TranslationLanguageGate {
    private var continuation: CheckedContinuation<[LyricsTranslationLanguage], Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func wait() async -> [LyricsTranslationLanguage] { await withCheckedContinuation { continuation = $0; let old = observers; observers = []; old.forEach { $0.resume() } } }
    func started() async { if continuation == nil { await withCheckedContinuation { observers.append($0) } } }
    func release() { let old = continuation; continuation = nil; old?.resume(returning: [.init(id: "en", name: "English")]) }
}
