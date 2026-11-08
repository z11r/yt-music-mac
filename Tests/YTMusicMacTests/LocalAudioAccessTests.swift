import AVFoundation
import Foundation
import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

@Suite("Local audio access contracts")
struct LocalAudioAccessTests {
    @Test func accessRemainsLeasedUntilExplicitRetirementAndReleaseIsIdempotent() async throws {
        let fixture = AccessFixture()
        let access = fixture.controller()
        let lease = try await access.acquire(fixture.record.reference, expectedLibraryID: fixture.library.libraryID)
        #expect(fixture.probe.counts == [1, 0, 1])
        #expect(!lease.isReleased)
        #expect(lease.reference == fixture.record.reference)
        lease.release(); lease.release()
        #expect(lease.isReleased)
        #expect(fixture.probe.counts == [1, 1, 1])
    }

    @Test func failedScopedGrantNeverFallsBackToOrdinaryAccess() async {
        let fixture = AccessFixture(mode: .securityScopedReadOnly, granted: false)
        let access = fixture.controller()
        await #expect(throws: LocalAudioAccessError.accessDenied) {
            try await access.acquire(fixture.record.reference, expectedLibraryID: fixture.library.libraryID)
        }
        #expect(fixture.probe.counts == [1, 0, 0])
    }

    @Test func explicitOrdinaryModeStillRequiresActualReadableSafeFileFacts() async throws {
        let fixture = AccessFixture(mode: .ordinary, granted: false)
        let lease = try await fixture.controller().acquire(fixture.record.reference, expectedLibraryID: fixture.library.libraryID)
        lease.release()
        #expect(fixture.probe.counts == [1, 0, 1])
        let denied = AccessFixture(granted: false, facts: accessFacts(readable: false))
        await #expect(throws: LocalAudioAccessError.unavailableFile) {
            try await denied.controller().acquire(denied.record.reference, expectedLibraryID: denied.library.libraryID)
        }
    }

    @Test func staleBookmarksWrongLibrariesAndRemoteURLsNeverBeginFileAccess() async {
        for fixture in [AccessFixture(stale: true), AccessFixture(url: URL(string: "file:///fixture/name%00suffix.wav")!),
                        AccessFixture(url: URL(string: "https://example.test/audio.mp3")!),
                        AccessFixture(url: URL(string: "file://remote.test/audio.mp3")!)] {
            await #expect(throws: (any Error).self) {
                try await fixture.controller().acquire(fixture.record.reference, expectedLibraryID: fixture.library.libraryID)
            }
            #expect(fixture.probe.counts == [0, 0, 0])
        }
        let fixture = AccessFixture()
        await #expect(throws: LocalAudioLibraryError.wrongLibrary) {
            try await fixture.controller().acquire(fixture.record.reference, expectedLibraryID: UUID())
        }
        #expect(fixture.probe.counts == [0, 0, 0])
    }

    @Test func unsafeOrChangedFilesBalanceEveryGrantedLease() async {
        let cases = [accessFacts(regular: false), accessFacts(symlink: true), accessFacts(alias: true),
                     accessFacts(local: false), accessFacts(available: false), accessFacts(readable: false),
                     accessFacts(identity: LocalAudioFileIdentity(volumeID: "other-volume", fileID: 99))]
        for facts in cases {
            let fixture = AccessFixture(facts: facts)
            await #expect(throws: (any Error).self) {
                try await fixture.controller().acquire(fixture.record.reference, expectedLibraryID: fixture.library.libraryID)
            }
            #expect(fixture.probe.counts == [1, 1, 1])
        }
    }

    @Test func canceledReadRetainsAdmissionUntilUncooperativeUnderlyingLoadSettles() async {
        let fixture = AccessFixture()
        let held = LocalAudioReadGate()
        let shared = LocalAudioReadAdmission()
        let access = LocalAudioAccessController(load: { await held.wait(); return fixture.library },
            bookmarks: fixture.probe, files: fixture.probe, admission: shared)
        let otherProfile = fixture.controller(admission: shared)
        let first = Task { try await access.acquire(fixture.record.reference, expectedLibraryID: fixture.library.libraryID) }
        await held.waitUntilStarted()
        first.cancel()
        await #expect(throws: LocalAudioAccessError.busy) {
            try await otherProfile.acquire(fixture.record.reference, expectedLibraryID: fixture.library.libraryID)
        }
        await held.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(fixture.probe.counts == [0, 0, 0])
        let retry = try? await access.acquire(fixture.record.reference, expectedLibraryID: fixture.library.libraryID)
        retry?.release()
        #expect(retry != nil)
    }

    @Test func onlyLocalUnadornedFileURLsCanReachAssetPreparationThroughTheURLPolicy() {
        for text in ["https://example.test/song.mp3", "data:audio/wav;base64,AA==", "file://host/song.mp3",
                     "file:///synthetic/song.mp3?token=private", "file:///synthetic/song.mp3#fragment"] {
            #expect(throws: LocalAudioAccessError.invalidURL) { try LocalAudioFilePolicy.validateURL(URL(string: text)!) }
        }
        #expect(throws: Never.self) { try LocalAudioFilePolicy.validateURL(URL(fileURLWithPath: "/synthetic/song.wav")) }
    }

    @Test func nativeAssetPolicyForbidsEveryExternalReferenceWithoutConstructingAnAsset() {
        let options = LocalAudioAssetPolicy.options
        #expect(options[AVURLAssetReferenceRestrictionsKey] as? UInt == AVAssetReferenceRestrictions.forbidAll.rawValue)
        #expect(options[AVURLAssetShouldSupportAliasDataReferencesKey] as? Bool == false)
        #expect(options[AVURLAssetAllowsCellularAccessKey] as? Bool == false)
        #expect(options[AVURLAssetAllowsExpensiveNetworkAccessKey] as? Bool == false)
        #expect(options[AVURLAssetAllowsConstrainedNetworkAccessKey] as? Bool == false)
    }

    @Test @MainActor func canceledAssetPreparationRetainsAdmissionWithoutInvokingNativeAdapters() async throws {
        let admission = LocalAudioPreparationAdmission()
        let held = LocalAudioReadGate()
        let first = Task { try await admission.perform { await held.wait(); return 42 } }
        await held.waitUntilStarted()
        first.cancel()
        #expect(admission.isBusy)
        await #expect(throws: LocalAudioAccessError.busy) { try await admission.perform { 0 } }
        await held.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(!admission.isBusy)
        let next = try await admission.perform { 43 }
        #expect(next == 43)
    }

    @Test func unsupportedAssetFactsFailWithoutInventingDurationOrCodecSupport() {
        let cases = [LocalAudioAssetFacts(isPlayable: false, hasAudio: true, hasVideo: false, hasProtectedContent: false, duration: 120),
            LocalAudioAssetFacts(isPlayable: true, hasAudio: false, hasVideo: false, hasProtectedContent: false, duration: 120),
            LocalAudioAssetFacts(isPlayable: true, hasAudio: true, hasVideo: true, hasProtectedContent: false, duration: 120),
            LocalAudioAssetFacts(isPlayable: true, hasAudio: true, hasVideo: false, hasProtectedContent: true, duration: 120),
            LocalAudioAssetFacts(isPlayable: true, hasAudio: true, hasVideo: false, hasProtectedContent: false, duration: .infinity),
            LocalAudioAssetFacts(isPlayable: true, hasAudio: true, hasVideo: false, hasProtectedContent: false, duration: 0)]
        for facts in cases { #expect(throws: LocalAudioAccessError.unsupportedAsset) { try facts.validate() } }
    }
}

@Suite("Local audio privacy exclusions") @MainActor
struct LocalAudioPrivacyTests {
    @Test func everyLocalMarkerIsExcludedFromExternalMetadataRadioLinksArtworkDragAndCredits() throws {
        let reference = LocalAudioReference(libraryID: UUID(), fileID: UUID())
        for source in 0...2 {
            var local = Track(id: source == 2 ? "local:orphan" : "abcdefghijk", title: "Private title", artist: "Private artist", contentKind: .song)
            local.origin = source == 0 ? .localFile : nil
            local.localAudioReference = source == 1 ? reference : nil
            local.artworkURL = URL(string: "https://example.test/private-art")
            local.creditsReference = SongCreditsReference(browseID: "MPTCfixture")
            #expect(PublicPlaybackMetadata(track: local) == nil)
            #expect(!QueueRecommendations.supports(local))
            #expect(!LibraryEditorRequest.addItems(tracks: [local]).isEnabled(by: .init(playlists: true)))
            var queue = PlaybackQueue(); queue.replace(with: [local]); _ = queue.beginPlayback()
            var radio = RadioQueueState<String>()
            #expect(radio.startSongRadio(in: queue, account: UUID()) == nil)
            #expect(radio.prefetch(for: queue, account: UUID(), autoplay: true) == nil)
            #expect(RadioQueueState<String>.newTracks([local], for: PlaybackQueue()).isEmpty)
            #expect(MusicLinkActions(track: local).link == nil)
            #expect(ArtworkSource.candidates(url: local.remoteArtworkURL, videoID: local.remoteArtworkVideoID, pixels: 128).isEmpty)
            #expect(throws: SongTransfer.TransferError.self) { try SongTransfer(tracks: [local], scope: UUID()).encoded() }
            let credits = SongCreditsSession(snapshot: { UUID() }, fetch: { _, _ in
                Issue.record("Local sources cannot fetch service credits"); return .unavailable
            })
            let accepted = credits.open(track: local, isCurrent: { true })
            #expect(!accepted)
            #expect(credits.task == nil)
            let lyrics = LyricsSession { _ in Issue.record("Local sources cannot fetch service lyrics"); return .unavailable }
            lyrics.load(track: local)
            #expect(lyrics.state == .unavailable && lyrics.videoID == nil && lyrics.task == nil)
            lyrics.load(videoID: "LoCaL:orphan")
            #expect(lyrics.state == .unavailable && lyrics.videoID == nil && lyrics.task == nil)
        }
    }

    @Test func catalogMetadataKeepsExistingNilOriginExplicitSongEligibility() {
        let track = Track(id: "abcdefghijk", title: "Song", artist: "Artist", contentKind: .song)
        #expect(PublicPlaybackMetadata(track: track) != nil)
        #expect(QueueRecommendations.supports(track))
        #expect(MusicLinkActions(track: track).link != nil)
    }
}

private struct AccessFixture: Sendable {
    let library: LocalAudioLibraryDocument
    let record: LocalAudioLibraryRecord
    let probe: LocalAudioAccessProbe
    init(mode: LocalAudioBookmarkMode = .ordinary, granted: Bool = true, stale: Bool = false,
         url: URL = URL(fileURLWithPath: "/synthetic/local-audio.wav"), facts: LocalAudioFileFacts = accessFacts()) {
        let reference = LocalAudioReference(libraryID: UUID(), fileID: UUID())
        record = LocalAudioLibraryRecord(reference: reference,
            metadata: LocalAudioMetadata(title: "Fixture", artist: "Artist", duration: 120, byteCount: 512),
            identity: LocalAudioFileIdentity(volumeID: "fixture-volume", fileID: 42),
            bookmark: LocalAudioBookmark(mode: mode, data: Data([1, 2, 3])))
        library = LocalAudioLibraryDocument(profileID: UUID(), libraryID: reference.libraryID, records: [record])
        probe = LocalAudioAccessProbe(url: url, granted: granted, stale: stale, facts: facts)
    }
    func controller(admission: LocalAudioReadAdmission = LocalAudioReadAdmission()) -> LocalAudioAccessController {
        LocalAudioAccessController(load: { library }, bookmarks: probe, files: probe, admission: admission)
    }
}

private final class LocalAudioAccessProbe: LocalAudioBookmarkAccessing, LocalAudioFileInspecting, @unchecked Sendable {
    let url: URL
    let granted: Bool
    let stale: Bool
    let facts: LocalAudioFileFacts
    private let lock = NSLock()
    private var values = [0, 0, 0]
    var counts: [Int] { lock.withLock { values } }
    init(url: URL, granted: Bool, stale: Bool, facts: LocalAudioFileFacts) {
        self.url = url; self.granted = granted; self.stale = stale; self.facts = facts
    }
    func create(for url: URL, mode: LocalAudioBookmarkMode) throws -> LocalAudioBookmark {
        Issue.record("Tests never create native bookmarks")
        return LocalAudioBookmark(mode: mode, data: Data([1]))
    }
    func resolve(_ bookmark: LocalAudioBookmark) throws -> LocalAudioResolvedBookmark { .init(url: url, isStale: stale) }
    func beginAccess(to url: URL) -> Bool { lock.withLock { values[0] += 1 }; return granted }
    func endAccess(to url: URL) { lock.withLock { values[1] += 1 } }
    func inspect(_ url: URL) throws -> LocalAudioFileFacts { lock.withLock { values[2] += 1 }; return facts }
}

private actor LocalAudioReadGate {
    private var started = false
    private var released = false
    private var pending: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        started = true; observers.forEach { $0.resume() }; observers.removeAll()
        if !released { await withCheckedContinuation { pending = $0 } }
    }
    func waitUntilStarted() async { if !started { await withCheckedContinuation { observers.append($0) } } }
    func release() { released = true; pending?.resume(); pending = nil }
}

private func accessFacts(identity: LocalAudioFileIdentity = .init(volumeID: "fixture-volume", fileID: 42),
    regular: Bool = true, symlink: Bool = false, alias: Bool = false, local: Bool = true,
    available: Bool = true, readable: Bool = true) -> LocalAudioFileFacts {
    LocalAudioFileFacts(identity: identity, byteCount: 512, isRegularFile: regular, isSymbolicLink: symlink,
        isAliasFile: alias, isLocalVolume: local, isLocallyAvailable: available, isReadable: readable)
}
