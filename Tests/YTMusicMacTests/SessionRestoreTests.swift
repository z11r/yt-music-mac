import Foundation
import Testing
import WebKit
import YouTubeMusic
@testable import YTMusicMac

@Suite("Session page ownership")
struct SessionPageOwnershipTests {
    @Test func aLateCompletionCannotFinishANewerRestore() {
        var state = SessionPageRestoreState()
        let old = state.begin()
        let beganOld = state.beginSynchronization(old)
        #expect(beganOld)
        let current = state.begin()
        let finishedOld = state.finish(old)
        #expect(!finishedOld)
        #expect(state.id == current)
        let finishedCurrent = state.finish(current)
        #expect(finishedCurrent)
        #expect(state.id == nil)
    }

    @Test func cancelledAndDuplicatePageCompletionsCannotSynchronize() {
        var state = SessionPageRestoreState()
        let id = state.begin()
        let first = state.beginSynchronization(id)
        let duplicate = state.beginSynchronization(id)
        let finished = state.finish(id)
        let cancelled = state.beginSynchronization(id)
        let finishedAgain = state.finish(id)
        #expect(first)
        #expect(!duplicate)
        #expect(finished)
        #expect(!cancelled)
        #expect(!finishedAgain)
    }
}

@MainActor
@Suite("Web session restoration", .serialized)
struct SessionRestoreTests {
    private func withSession(_ body: @MainActor (WebSession, WKWebsiteDataStore, UserDefaults) async throws -> Void) async throws {
        let name = "YTMusicMacTests.SessionRestore.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        let store = WKWebsiteDataStore.nonPersistent()
        let session = WebSession(dataStore: store, credentials: MusicSessionStore(), preferences: preferences)
        try await body(session, store, preferences)
    }

    private func addSyntheticCookie(to store: WKWebsiteDataStore) async throws {
        let cookie = try #require(HTTPCookie(properties: [
            .name: "SAPISID", .value: "isolated-test-value", .domain: ".youtube.com", .path: "/", .secure: "TRUE",
        ]))
        await store.httpCookieStore.setCookie(cookie)
    }

    @Test func aSavedSessionUsesTheSuppliedPageWithoutCreatingALoginView() async throws {
        try await withSession { session, store, _ in
            try await addSyntheticCookie(to: store)
            var requests = 0
            await session.restore { requests += 1; return true }
            #expect(requests == 1)
            #expect(session.loginWebView == nil)
            #expect(session.isWorking)
            #expect(!session.isSignedIn)
            #expect(await session.credentials.snapshot().accountID == nil)
            session.sessionRestoreFailed()
        }
    }

    @Test func noCookieDoesNotCreateOrLoadAWebPage() async throws {
        try await withSession { session, _, _ in
            await session.restore {
                Issue.record("An empty session must not load a restoration page.")
                return true
            }
            #expect(session.loginWebView == nil)
            #expect(!session.isWorking)
        }
    }

    @Test func failedRestorationKeepsCookiesAndReportsAnAccountAction() async throws {
        try await withSession { session, store, _ in
            try await addSyntheticCookie(to: store)
            await session.restore { false }
            #expect(!session.isWorking)
            #expect(!session.isSignedIn)
            #expect(session.errorMessage?.contains("Open Account") == true)
            let cookies = await store.httpCookieStore.allCookies()
            #expect(cookies.contains { $0.name == "SAPISID" && $0.value == "isolated-test-value" })
            #expect(session.loginWebView == nil)
        }
    }

    @Test func aClosedRestoreIgnoresALateFailure() async throws {
        try await withSession { session, store, _ in
            try await addSyntheticCookie(to: store)
            await session.restore { true }
            session.closeLogin()
            session.sessionRestoreFailed()
            #expect(session.errorMessage == nil)
            #expect(!session.isWorking)
        }
    }
}
