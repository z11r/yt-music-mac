import Foundation
import Testing
import YouTubeMusic
@testable import YTMusicMac

@Suite("Contributor portrait native admission") @MainActor
struct ArtworkLoadAdmissionTests {
    @Test func originalCallerCanPassButRevocationBeforeActualCacheAdmissionStartsNothing() async {
        let state = PortraitAdmissionState(), gate = PortraitAdmissionGate(), fallback = UnusedPortraitLoader()
        let cache = portraitCache(fallback), admission = fakeAdmission(state)
        let pending = Task {
            guard state.isCurrent else { return false }
            state.callerPassed = true
            await gate.hold()
            _ = await cache.image(for: portraitRequest, admission: admission)
            return true
        }
        await gate.waitUntilHeld()
        #expect(state.callerPassed && state.starts.isEmpty)
        state.isCurrent = false
        await gate.release()
        #expect(await pending.value)
        #expect(state.starts.isEmpty)
        #expect(await fallback.count == 0)
        #expect(cache.memory.usage().count == 0)
    }

    @Test func unchangedOwnerStartsExactlyOnceThroughTheRealGuardedCachePath() async {
        let state = PortraitAdmissionState(), gate = PortraitAdmissionGate(), fallback = UnusedPortraitLoader()
        let cache = portraitCache(fallback), admission = fakeAdmission(state)
        let pending = Task {
            state.callerPassed = state.isCurrent
            await gate.hold()
            return await cache.image(for: portraitRequest, admission: admission)
        }
        await gate.waitUntilHeld()
        #expect(state.callerPassed && state.starts.isEmpty)
        await gate.release()
        // A fake transport error ends the read without invoking a native decoder.
        #expect(await pending.value == nil)
        #expect(state.starts == [portraitRequest.url!])
        #expect(await fallback.count == 0)
    }

    @Test func closingOrReplacingThePresentationRevokesItsQueuedPortrait() async {
        let replacements: [UUID?] = [nil, UUID()]
        for replacement in replacements {
            let state = PortraitAdmissionState(), gate = PortraitAdmissionGate(), fallback = UnusedPortraitLoader()
            let original = state.presentation
            let admission = ArtworkLoadAdmission(isCurrent: {
                state.isCurrent && state.presentation == original
            }, start: { url, continuation, _ in
                MainActor.preconditionIsolated()
                state.starts.append(url); continuation.resume(throwing: URLError(.zeroByteResource))
            })
            let cache = portraitCache(fallback)
            let pending = Task {
                state.callerPassed = state.isCurrent
                await gate.hold()
                return await cache.image(for: portraitRequest, admission: admission)
            }
            await gate.waitUntilHeld()
            state.presentation = replacement
            await gate.release()
            #expect(await pending.value == nil)
            #expect(state.callerPassed && state.isCurrent && state.starts.isEmpty)
            #expect(await fallback.count == 0)
        }
    }

    @Test func disappearingOldPresentationCannotClearANewerOneWithTheSameTarget() throws {
        let collaboration = try #require(MusicPlaylistCollaboration(label: "Synthetic contributors"))
        let old = PlaylistContributorsPresentation(profile: UUID(), account: UUID(), destination: .explore, collaboration: collaboration)
        let new = PlaylistContributorsPresentation(profile: old.profile, account: old.account, destination: old.destination, collaboration: collaboration)
        var current: PlaylistContributorsPresentation? = old
        old.removeIfCurrent(from: &current)
        #expect(current == nil)
        current = new
        old.removeIfCurrent(from: &current)
        #expect(current?.id == new.id)
        new.removeIfCurrent(from: &current)
        #expect(current == nil)
    }

    @Test func canceledQueuedNativeAdmissionCannotCreateOrResumeATransfer() async {
        let state = PortraitAdmissionState(), gate = PortraitAdmissionGate()
        let admission = fakeAdmission(state)
        let pending = Task {
            state.callerPassed = state.isCurrent
            await gate.hold() // Intentionally retains cancellation until explicitly released.
            return try await admission.load(portraitRequest.url!)
        }
        await gate.waitUntilHeld()
        pending.cancel()
        await gate.release()
        do { _ = try await pending.value; Issue.record("Canceled admission returned data") }
        catch { #expect(error is CancellationError) }
        #expect(state.callerPassed && state.starts.isEmpty)
    }

    @Test func canceledQueuedCacheReadAndUntrustedURLNeverReachEitherStarter() async {
        let state = PortraitAdmissionState(), gate = PortraitAdmissionGate(), fallback = UnusedPortraitLoader()
        let cache = portraitCache(fallback), admission = fakeAdmission(state)
        let pending = Task {
            state.callerPassed = state.isCurrent
            await gate.hold()
            return await cache.image(for: portraitRequest, admission: admission)
        }
        await gate.waitUntilHeld()
        pending.cancel(); await gate.release()
        #expect(await pending.value == nil)
        do { _ = try await admission.load(URL(string: "https://example.invalid/private")!); Issue.record("Untrusted URL was admitted") }
        catch { #expect(error is ArtworkTransfer.Failure) }
        #expect(state.starts.isEmpty)
        #expect(await fallback.count == 0)
    }
}

private let portraitRequest = ArtworkRequest(url: URL(string: "https://yt3.googleusercontent.com/synthetic-portrait"), videoID: nil, pixels: 64)
@MainActor private final class PortraitAdmissionState {
    var isCurrent = true
    var presentation: UUID? = UUID()
    var callerPassed = false
    var starts: [URL] = []
}
@MainActor private func fakeAdmission(_ state: PortraitAdmissionState) -> ArtworkLoadAdmission {
    ArtworkLoadAdmission(isCurrent: { state.isCurrent }, start: { url, continuation, _ in
        MainActor.preconditionIsolated()
        state.starts.append(url)
        continuation.resume(throwing: URLError(.zeroByteResource))
    })
}
private func portraitCache(_ fallback: UnusedPortraitLoader) -> ArtworkCache {
    ArtworkCache(memory: BoundedMemoryCache(byteLimit: 1_024 * 1_024, countLimit: 8, observesMemoryPressure: false),
                 load: { _ in await fallback.load() })
}
private actor UnusedPortraitLoader {
    private(set) var count = 0
    func load() -> Data { count += 1; return Data([1]) }
}
private actor PortraitAdmissionGate {
    private var entered = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true; waiting?.resume(); waiting = nil
        await withCheckedContinuation { held = $0 }
    }
    func waitUntilHeld() async {
        if !entered { await withCheckedContinuation { waiting = $0 } }
    }
    func release() { held?.resume(); held = nil }
}
