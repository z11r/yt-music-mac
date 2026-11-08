import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

@MainActor struct LastFMTests {
    private let profile = String(repeating: "e", count: 64)
    private let other = String(repeating: "f", count: 64)
    private let app = LastFMAppCredentials(apiKey: String(repeating: "a", count: 32), sharedSecret: String(repeating: "b", count: 32))
    private let requestToken = String(repeating: "c", count: 32)
    private let song = Track(id: "abcDEF12_-3", title: "Fixture Song", artist: "Fixture Artist", album: "Fixture Album", contentKind: .song)

    @Test func signingSortsRawUTF8AndExcludesFormatCallbackAndTheSignature() {
        let fields = ["method": "auth.getSession", "api_key": app.apiKey, "token": requestToken, "format": "json", "callback": "excluded", "api_sig": "excluded"]
        #expect(LastFMAPI.signature(fields, secret: app.sharedSecret) == "b33bd3b34c3425aa73ac992c9ac15ea7")
        #expect(LastFMAPI.signature(["artist[1]": "Björk & +", "artist[10]": "Other", "method": "track.scrobble", "format": "json", "callback": "skip"], secret: app.sharedSecret) == "67374d1de52127eec11453076c494805")
        #expect(LastFMAPI.form(["track": "Björk & + /"]) == "track=Bj%C3%B6rk%20%26%20%2B%20%2F")
    }

    @Test func desktopAuthUsesSignedMethodsAndApprovalContainsOnlyAppKeyAndToken() async throws {
        let transport = LastFMFakeTransport([.response(tokenResponse()), .response(sessionResponse())])
        let api = LastFMAPI(transport: transport)
        let token = try await api.requestToken(application: app)
        let credentials = try await api.getSession(application: app, token: token)
        #expect(credentials.username == "fixture-user" && credentials.sessionKey == String(repeating: "d", count: 32))
        let requests = await transport.requests
        #expect(requests.count == 2 && requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
        let session = fields(requests[1])
        #expect(session["method"] == "auth.getSession" && session["format"] == "json" && session["token"] == requestToken)
        #expect(session["api_sig"] == "b33bd3b34c3425aa73ac992c9ac15ea7")
        let url = try #require(LastFMAPI.approvalURL(application: app, token: token))
        #expect(url.scheme == "https" && url.host == "www.last.fm" && url.absoluteString.hasPrefix("https://www.last.fm/api/auth/?"))
        #expect(Set(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map(\.name)) == ["api_key", "token"])
        #expect(!url.absoluteString.contains(app.sharedSecret))
        #expect(!requests.contains { $0.url!.absoluteString.contains(app.sharedSecret) })
    }

    @Test func missingOrMalformedAppCredentialsNeverReachTheTransport() async {
        for bad in [LastFMAppCredentials(apiKey: "", sharedSecret: ""), .init(apiKey: String(repeating: "g", count: 31), sharedSecret: app.sharedSecret), .init(apiKey: app.apiKey, sharedSecret: "secret\nheader")] {
            let transport = LastFMFakeTransport([])
            await #expect(throws: LastFMAPIError.invalidCredentials) { _ = try await LastFMAPI(transport: transport).requestToken(application: bad) }
            #expect(await transport.requests.isEmpty)
            #expect(LastFMAPI.approvalURL(application: bad, token: requestToken) == nil)
        }
    }

    @Test func authErrorsAreTypedAndMalformedSuccessDoesNotCreateASession() async {
        for (code, expected) in [(14, LastFMAPIError.notAuthorized), (15, .expired), (13, .rejected)] {
            let transport = LastFMFakeTransport([.response(errorResponse(code))])
            await #expect(throws: expected) { _ = try await LastFMAPI(transport: transport).getSession(application: app, token: requestToken) }
            #expect(await transport.requests.count == 1)
        }
        let transport = LastFMFakeTransport([.response(json(["session": ["name": "fixture-user", "key": "bad"]]))])
        await #expect(throws: LastFMAPIError.uncertain) { _ = try await LastFMAPI(transport: transport).getSession(application: app, token: requestToken) }
    }

    @Test func scrobbleIsOneSignedPOSTWithDisclosedFieldsOnly() async throws {
        let transport = LastFMFakeTransport([.response(accepted())])
        #expect(await LastFMAPI(transport: transport).submit(earned(), credentials: credentials()) == .confirmed)
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST" && request.url?.absoluteString == "https://ws.audioscrobbler.com/2.0/")
        let body = fields(request)
        #expect(body["artist"] == song.artist && body["track"] == song.title && body["album"] == song.album)
        #expect(body["timestamp"] == "1700000000" && body["duration"] == "120")
        #expect(body["chosenByUser"] == nil && body["api_sig"] == LastFMAPI.signature(body, secret: app.sharedSecret))
        let text = String(decoding: request.httpBody!, as: UTF8.self)
        for value in [song.id, profile, app.sharedSecret, "Cookie", "artwork", "episode"] { #expect(!text.contains(value)) }
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func knownSelectionProvenanceIsSignedAndRetainedWithTheLogicalListen() async throws {
        let f = fixture([.response(accepted())]); defer { f.remove() }
        await ready(f); await hear(f, chosenByUser: false); await f.coordinator.waitForDeliveries()
        let request = try #require(await f.transport.requests.first)
        #expect(fields(request)["chosenByUser"] == "0")
        let value = try f.store.load(profile: profile)
        #expect(value.currentProvenance?.chosenByUser == false && value.outbox.first?.chosenByUser == false)
        let restored = f.restarted(); _ = await bind(restored)
        let play = try #require(value.ledger.current)
        let occurrence = PlaybackOccurrence(sessionID: UUID(), entryID: play.entryID, trackID: song.id, generation: 2)
        await restored.coordinator.begin(track: song, occurrence: occurrence, intent: .continuation, expectedScope: restored.scope, chosenByUser: true)
        #expect(try restored.store.load(profile: profile).currentProvenance?.chosenByUser == false)
        let transport = LastFMFakeTransport([.response(accepted())])
        #expect(await LastFMAPI(transport: transport).submit(earned(), credentials: credentials(), chosenByUser: true) == .confirmed)
        #expect(fields(try #require(await transport.requests.first))["chosenByUser"] == "1")
    }

    @Test func acceptedIgnoredRefusedAndUncertainRepliesAreDistinct() async {
        let outcomes: [(ScrobbleHTTPResponse, LastFMSubmissionOutcome)] = [
            (accepted(), .confirmed), (accepted(ignored: true), .ignored), (errorResponse(9), .authenticationRejected),
            (errorResponse(11), .retryable), (errorResponse(16), .retryable), (errorResponse(6), .rejected),
            (json([:]), .uncertain), (accepted(status: 500), .uncertain),
            (json(["scrobbles": ["@attr": ["accepted": Int.max, "ignored": Int.max]]]), .uncertain),
            (accepted(timestamp: 1_700_000_001), .uncertain),
        ]
        for (reply, expected) in outcomes {
            let transport = LastFMFakeTransport([.response(reply)])
            #expect(await LastFMAPI(transport: transport).submit(earned(), credentials: credentials()) == expected)
            #expect(await transport.requests.count == 1)
        }
        let transport = LastFMFakeTransport([.failure])
        #expect(await LastFMAPI(transport: transport).submit(earned(), credentials: credentials()) == .uncertain)
        #expect(await transport.requests.count == 1)
    }

    @Test func defaultOffDoesNotReadKeychainCreateFilesOrRequestAuthorization() async throws {
        let f = fixture([]); defer { f.remove() }
        _ = await bind(f)
        _ = await f.coordinator.setEnabled(true, expectedScope: f.scope, revision: revision(f))
        #expect(!FileManager.default.fileExists(atPath: f.directory.path))
        #expect(await f.secrets.reads == 0)
        #expect(await f.transport.requests.isEmpty)
        #expect(await !f.coordinator.viewState().enabled)
    }

    @Test func configuredDesktopFlowRequiresSeparateExplicitStepsAndOptIn() async throws {
        let f = fixture([.response(tokenResponse()), .response(sessionResponse())]); defer { f.remove() }
        _ = await bind(f)
        let saved = await f.coordinator.configure(application: app, expectedScope: f.scope, revision: revision(f))
        #expect(saved.configured && !saved.connected && !saved.enabled && !saved.working)
        #expect(await f.transport.requests.isEmpty)
        let preparing = await f.coordinator.beginAuthorization(expectedScope: f.scope, revision: revision(f))
        let id = try #require(preparing.authorizationID)
        #expect(!preparing.enabled && !preparing.connected && !preparing.working)
        #expect(await f.coordinator.approvalURL(expectedScope: f.scope, authorizationID: id) != nil)
        let complete = await f.coordinator.completeAuthorization(expectedScope: f.scope, authorizationID: id, revision: revision(f))
        #expect(complete.connected && !complete.enabled && !complete.working && complete.authorizationID == nil)
        let enabled = await f.coordinator.setEnabled(true, expectedScope: f.scope, revision: revision(f))
        #expect(enabled.enabled)
        #expect(await f.secrets.values[profile]?.sessionKey == credentials().sessionKey)
        let file = f.directory.appendingPathComponent(profile + ".json")
        let stored = try String(contentsOf: file, encoding: .utf8)
        for excluded in [app.apiKey, app.sharedSecret, requestToken, credentials().sessionKey!] { #expect(!stored.contains(excluded)) }
    }

    @Test func authorizationExpiryAndStaleIDsCannotConsumeAnotherApproval() async throws {
        let f = fixture([.response(tokenResponse()), .response(tokenResponse())]); defer { f.remove() }
        await configure(f)
        let first = await f.coordinator.beginAuthorization(expectedScope: f.scope, revision: revision(f))
        let old = try #require(first.authorizationID)
        let second = await f.coordinator.beginAuthorization(expectedScope: f.scope, revision: revision(f))
        let current = try #require(second.authorizationID)
        _ = await f.coordinator.completeAuthorization(expectedScope: f.scope, authorizationID: old, revision: revision(f))
        #expect(await f.coordinator.viewState().authorizationID == current)
        f.clock.set(3_601)
        #expect(await f.coordinator.approvalURL(expectedScope: f.scope, authorizationID: current) == nil)
        _ = await f.coordinator.completeAuthorization(expectedScope: f.scope, authorizationID: current, revision: revision(f))
        #expect(await f.coordinator.viewState().authorizationID == nil)
        #expect(await f.transport.requests.count == 2)
    }

    @Test func explicitNotAuthorizedCanBeCompletedAgainButUncertainExchangeIsConsumed() async throws {
        let f = fixture([.response(tokenResponse()), .response(errorResponse(14)), .failure]); defer { f.remove() }
        await configure(f)
        let state = await f.coordinator.beginAuthorization(expectedScope: f.scope, revision: revision(f))
        let id = try #require(state.authorizationID)
        _ = await f.coordinator.completeAuthorization(expectedScope: f.scope, authorizationID: id, revision: revision(f))
        #expect(await f.coordinator.viewState().authorizationID == id)
        _ = await f.coordinator.completeAuthorization(expectedScope: f.scope, authorizationID: id, revision: revision(f))
        #expect(await f.coordinator.viewState().authorizationID == nil)
        _ = await f.coordinator.completeAuthorization(expectedScope: f.scope, authorizationID: id, revision: revision(f))
        #expect(await f.transport.requests.count == 3)
        #expect(await !f.coordinator.viewState().connected)
    }

    @Test func lateAuthorizationAfterAccountChangeCannotStoreANewSession() async throws {
        let f = fixture([.response(tokenResponse()), .hold]); defer { f.remove() }
        await configure(f)
        let state = await f.coordinator.beginAuthorization(expectedScope: f.scope, revision: revision(f))
        let id = try #require(state.authorizationID)
        let finishing = Task { await f.coordinator.completeAuthorization(expectedScope: f.scope, authorizationID: id, revision: revision(f)) }
        await f.transport.waitForHold()
        let next = UUID(); f.coordinator.gate.revoke(to: next)
        _ = await f.coordinator.bind(profile: other, scope: next)
        await f.transport.finish(sessionResponse())
        _ = await finishing.value
        #expect(await f.secrets.values[profile]?.sessionKey == nil)
        #expect(await f.secrets.values[other] == nil)
        #expect(await !f.coordinator.viewState().connected)
        #expect(try !f.store.load(profile: other).configured)
    }

    @Test func savedSendingAndUncertainAttemptsNeverReplayOnRestartOrSendUnsent() async throws {
        let f = fixture([]); defer { f.remove() }
        var document = savedDocument(enabled: true)
        document.outbox = [.init(listen: earned(), username: "fixture-user", state: .sending)]
        try f.store.save(document); try! await f.secrets.store(credentials(), profile: profile)
        let state = await bind(f)
        #expect(state.uncertain == 1 && state.paused)
        _ = await f.coordinator.sendUnsent(expectedScope: f.scope)
        await f.coordinator.waitForDeliveries()
        #expect(await f.transport.requests.isEmpty)
        #expect(try f.store.load(profile: profile).outbox.first?.state == .uncertain)
    }

    @Test func temporaryRefusalRequiresExplicitRetryAndKeepsTheOriginalTimestamp() async throws {
        let f = fixture([.response(errorResponse(11)), .response(accepted())]); defer { f.remove() }
        await ready(f)
        await hear(f)
        await f.coordinator.waitForDeliveries()
        #expect(await f.transport.requests.count == 1)
        #expect(try f.store.load(profile: profile).outbox.first?.state == .retryable)
        _ = await f.coordinator.sendUnsent(expectedScope: f.scope)
        #expect(await f.transport.requests.count == 1)
        _ = await f.coordinator.retryRefused(expectedScope: f.scope)
        await f.coordinator.waitForDeliveries()
        let requests = await f.transport.requests
        #expect(requests.count == 2 && fields(requests[0]) == fields(requests[1]))
        #expect(try f.store.load(profile: profile).outbox.first?.state == .confirmed)
    }

    @Test func uncertainPostCannotBeSelectedByEitherExplicitSendButton() async throws {
        let f = fixture([.failure]); defer { f.remove() }
        await ready(f); await hear(f); await f.coordinator.waitForDeliveries()
        #expect(try f.store.load(profile: profile).outbox.first?.state == .uncertain)
        _ = await f.coordinator.sendUnsent(expectedScope: f.scope)
        _ = await f.coordinator.retryRefused(expectedScope: f.scope)
        await f.coordinator.waitForDeliveries()
        let restored = f.restarted(); _ = await bind(restored)
        await restored.coordinator.waitForDeliveries()
        #expect(await f.transport.requests.count == 1)
        #expect(await restored.coordinator.viewState().uncertain == 1)
    }

    @Test func restoredBacklogAttemptsOnlyFiveNewPostsPerRun() async throws {
        let replies = (0..<5).map { LastFMFakeTransport.Step.response(accepted(timestamp: 1_700_000_000 + $0)) }
        let f = fixture(replies); defer { f.remove() }
        var document = savedDocument(enabled: true); document.paused = true
        document.outbox = (0..<100).map { index in
            .init(listen: .init(entryID: UUID(), metadata: ListenMetadata(track: song)!, listenedAt: 1_700_000_000 + index, duration: 120),
                  username: "fixture-user", state: .ready)
        }
        try f.store.save(document); try! await f.secrets.store(credentials(), profile: profile)
        _ = await bind(f)
        #expect(await f.transport.requests.isEmpty)
        _ = await f.coordinator.sendUnsent(expectedScope: f.scope)
        await f.coordinator.waitForDeliveries()
        #expect(await f.transport.requests.count == 5)
        #expect(await f.coordinator.viewState().ready == 95)
    }

    @Test func oldSessionRejectionCannotInvalidateNewerAuthorization() async throws {
        let f = fixture([.hold, .response(tokenResponse()), .response(sessionResponse())]); defer { f.remove() }
        await ready(f); await hear(f); await f.transport.waitForHold()
        let prepared = await f.coordinator.beginAuthorization(expectedScope: f.scope, revision: revision(f))
        _ = await f.coordinator.completeAuthorization(expectedScope: f.scope, authorizationID: try #require(prepared.authorizationID), revision: revision(f))
        _ = await f.coordinator.setEnabled(true, expectedScope: f.scope, revision: revision(f))
        let latest = try f.store.load(profile: profile).credentialRevision
        #expect(latest != credentials().revision)
        await f.transport.finish(errorResponse(9)); await f.coordinator.waitForDeliveries()
        let saved = try f.store.load(profile: profile)
        #expect(!saved.sessionRejected && saved.enabled && saved.credentialRevision == latest)
        #expect(await f.coordinator.viewState().connected)
        #expect(f.coordinator.gate.allows(scope: f.scope))
    }

    @Test func rejectedSessionCannotReopenAfterRestartUntilAuthorizationCompletes() async throws {
        let f = fixture([.response(errorResponse(9))]); defer { f.remove() }
        await ready(f); await hear(f); await f.coordinator.waitForDeliveries()
        let document = try f.store.load(profile: profile)
        #expect(document.sessionRejected && !document.enabled && document.outbox.first?.state == .needsAuthorization)
        let restart = f.restarted()
        _ = await bind(restart)
        let state = await restart.coordinator.setEnabled(true, expectedScope: restart.scope, revision: revision(restart))
        #expect(!state.enabled && !state.connected)
        #expect(await f.transport.requests.count == 1)
    }

    @Test func providerSwitchIsRefusedWhileAnotherUsersListensArePending() async throws {
        let f = fixture([.response(tokenResponse()), .response(sessionResponse(name: "another-user"))]); defer { f.remove() }
        var document = savedDocument(enabled: false)
        document.outbox = [.init(listen: earned(), username: "fixture-user", state: .uncertain)]
        try f.store.save(document); try! await f.secrets.store(credentials(), profile: profile)
        _ = await bind(f)
        let state = await f.coordinator.beginAuthorization(expectedScope: f.scope, revision: revision(f))
        _ = await f.coordinator.completeAuthorization(expectedScope: f.scope, authorizationID: try #require(state.authorizationID), revision: revision(f))
        #expect(await f.secrets.values[profile]?.username == "fixture-user")
        #expect(await f.coordinator.viewState().username == "fixture-user")
    }

    @Test func lateSubmissionAcknowledgmentCannotRecreateDisconnectedData() async throws {
        let f = fixture([.hold]); defer { f.remove() }
        await ready(f); await hear(f); await f.transport.waitForHold()
        _ = await f.coordinator.disconnect(expectedScope: f.scope, revision: revision(f))
        await f.transport.finish(accepted()); await f.coordinator.waitForDeliveries()
        #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent(profile + ".json").path))
        #expect(await f.secrets.values[profile] == nil)
        #expect(await f.transport.requests.count == 1)
    }

    @Test func revokedConsentAndAccountScopesCannotBeReactivated() async throws {
        let f = fixture([]); defer { f.remove() }
        await ready(f)
        let old = revision(f)
        let current = revision(f)
        _ = await f.coordinator.setEnabled(false, expectedScope: f.scope, revision: current)
        _ = await f.coordinator.setEnabled(true, expectedScope: f.scope, revision: old)
        #expect(!f.coordinator.gate.allows(scope: f.scope))
        #expect(await !f.coordinator.viewState().enabled)
        let next = UUID(); f.coordinator.gate.revoke(to: next)
        _ = await f.coordinator.beginAuthorization(expectedScope: f.scope, revision: old)
        #expect(await f.transport.requests.isEmpty)
    }

    @Test func outboxFilesRejectOverflowAndRetainMalformedAndNewerDocuments() throws {
        let f = fixture([]); defer { f.remove() }
        var document = savedDocument(enabled: false)
        document.outbox = (0..<101).map { _ in .init(listen: earned(), username: "fixture-user", state: .ready) }
        #expect(throws: LastFMStoreError.invalidData) { try f.store.save(document) }
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
        let url = f.directory.appendingPathComponent(profile + ".json")
        try Data("{broken".utf8).write(to: url)
        #expect(throws: (any Error).self) { try f.store.save(savedDocument(enabled: false)) }
        #expect(try Data(contentsOf: url) == Data("{broken".utf8))
        document = savedDocument(enabled: false); document.version = 2
        let newer = try JSONEncoder().encode(document); try newer.write(to: url)
        #expect(throws: LastFMStoreError.unsupportedVersion) { _ = try f.store.load(profile: profile) }
        #expect(throws: (any Error).self) { try f.store.save(savedDocument(enabled: false)) }
        #expect(try Data(contentsOf: url) == newer)
    }

    @Test func credentialStorageFailureLeavesScrobblingOffWithoutAuthorizationRequests() async throws {
        let f = fixture([]); defer { f.remove() }
        _ = await bind(f)
        await f.secrets.failWrites(true)
        let state = await f.coordinator.configure(application: app, expectedScope: f.scope, revision: revision(f))
        #expect(!state.enabled && !state.configured && !state.connected && !state.working)
        #expect(await f.transport.requests.isEmpty)
        #expect(try !f.store.load(profile: profile).configured)
    }

    @Test func failedReplacementAuthorizationCannotFallBackToTheOldSavedSession() async throws {
        let f = fixture([.response(tokenResponse()), .response(sessionResponse())]); defer { f.remove() }
        await ready(f)
        let prepared = await f.coordinator.beginAuthorization(expectedScope: f.scope, revision: revision(f))
        #expect(!prepared.enabled && !prepared.connected)
        await f.secrets.failWrites(true)
        let result = await f.coordinator.completeAuthorization(expectedScope: f.scope, authorizationID: try #require(prepared.authorizationID), revision: revision(f))
        #expect(!result.enabled && !result.connected)
        let restored = f.restarted(); _ = await bind(restored)
        let enabled = await restored.coordinator.setEnabled(true, expectedScope: restored.scope, revision: revision(restored))
        #expect(!enabled.enabled && !enabled.connected)
        #expect(try f.store.load(profile: profile).sessionRejected)
    }

    @Test func invalidReplacementConfigurationClosesTheOldSessionWithoutKeychainWrites() async throws {
        let f = fixture([]); defer { f.remove() }
        await ready(f)
        let result = await f.coordinator.configure(application: .init(apiKey: "invalid", sharedSecret: "invalid"), expectedScope: f.scope, revision: revision(f))
        #expect(!result.enabled && !result.connected && !f.coordinator.gate.allows(scope: f.scope))
        #expect(await f.secrets.values[profile]?.sessionKey == credentials().sessionKey)
        #expect(await f.transport.requests.isEmpty)
    }

    @Test func unsavedAttemptCannotSendOrOverwriteANewerLocalDocument() async throws {
        let f = fixture([]); defer { f.remove() }
        await ready(f)
        var newer = savedDocument(enabled: true); newer.version = 2
        let data = try JSONEncoder().encode(newer)
        let url = f.directory.appendingPathComponent(profile + ".json")
        try data.write(to: url)
        await hear(f); await f.coordinator.waitForDeliveries()
        #expect(await f.transport.requests.isEmpty)
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func lastFMAndListenBrainzUseIndependentLogicalReceipts() async throws {
        let f = fixture([.response(accepted())]); defer { f.remove() }
        await ready(f)
        let lbDirectory = f.directory.appendingPathComponent("listenbrainz", isDirectory: true)
        let transport = LastFMFakeTransport([.response(json(["valid": true, "user_name": "fixture-user"])), .response(json(["status": "ok"]))])
        let lb = ListenBrainzCoordinator(store: .init(directory: lbDirectory), tokens: LastFMLBTokenFixture(), api: .init(transport: transport))
        let scope = UUID(); lb.gate.revoke(to: scope)
        _ = await lb.bind(profile: profile, scope: scope)
        _ = await lb.connect(token: "fixture-only-token", expectedScope: scope)
        _ = await lb.setEnabled(true, expectedScope: scope)
        let occurrence = occurrence()
        await f.coordinator.begin(track: song, occurrence: occurrence, intent: .newListen, expectedScope: f.scope)
        await lb.begin(track: song, occurrence: occurrence, intent: .newListen, expectedScope: scope)
        for time in 1...61 {
            await f.coordinator.sample(occurrence: occurrence, position: Double(time), duration: 120, ended: false, expectedScope: f.scope,
                                       observedTime: Double(time), observedWallTime: Date(timeIntervalSince1970: 1_700_000_000))
            await lb.sample(occurrence: occurrence, position: Double(time), duration: 120, ended: false, expectedScope: scope,
                            observedTime: Double(time), observedWallTime: Date(timeIntervalSince1970: 1_700_000_000))
        }
        await f.coordinator.waitForDeliveries(); await lb.waitForDeliveries()
        #expect(await f.transport.requests.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(await transport.requests.filter { $0.httpMethod == "POST" }.count == 1)
        let first = try #require(f.store.load(profile: profile).ledger.current?.id)
        let second = try #require(ListenBrainzStore(directory: lbDirectory).load(profile: profile).ledger.current?.id)
        #expect(first != second)
    }

    @Test func localizedSettingsHaveMatchingEnglishFrenchKeysAndFormatCounts() throws {
        let root = AppIdentity.resourceBundle
        let en = try #require(root.url(forResource: "LastFM", withExtension: "strings", subdirectory: "en.lproj"))
        let fr = try #require(root.url(forResource: "LastFM", withExtension: "strings", subdirectory: "fr.lproj"))
        let english = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: en), format: nil) as? [String: String])
        let french = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: fr), format: nil) as? [String: String])
        #expect(english.count >= 50 && Set(english.keys) == Set(french.keys))
        #expect(french.values.allSatisfy { !$0.isEmpty })
        let frenchBundle = try #require(Bundle(url: fr.deletingLastPathComponent()))
        let text = LastFMText.counts(ready: 2, uncertain: 3, refused: 4, ignored: 5, bundle: frenchBundle)
        #expect(text.contains("Non envoyées : 2") && text.contains("Ignorées : 5"))
    }

    private func credentials() -> LastFMSavedCredentials { .init(application: app, revision: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, username: "fixture-user", sessionKey: String(repeating: "d", count: 32)) }
    private func earned() -> EarnedListen { .init(entryID: UUID(), metadata: ListenMetadata(track: song)!, listenedAt: 1_700_000_000, duration: 120) }
    private func occurrence() -> PlaybackOccurrence { .init(sessionID: UUID(), entryID: UUID(), trackID: song.id, generation: 1) }
    private func fixture(_ steps: [LastFMFakeTransport.Step]) -> LastFMFixture { .init(steps: steps) }
    private func revision(_ f: LastFMFixture) -> UUID { f.coordinator.gate.changeIntent(scope: f.scope)! }
    private func bind(_ f: LastFMFixture) async -> LastFMViewState {
        f.coordinator.gate.revoke(to: f.scope)
        return await f.coordinator.bind(profile: profile, scope: f.scope)
    }
    private func configure(_ f: LastFMFixture) async {
        _ = await bind(f)
        _ = await f.coordinator.configure(application: app, expectedScope: f.scope, revision: revision(f))
    }
    private func savedDocument(enabled: Bool) -> LastFMDocument {
        var value = LastFMDocument(profile: profile); value.configured = true; value.appFingerprint = app.fingerprint
        value.username = "fixture-user"; value.enabled = enabled; value.credentialRevision = credentials().revision
        return value
    }
    private func ready(_ f: LastFMFixture) async {
        try! f.store.save(savedDocument(enabled: true))
        try! await f.secrets.store(credentials(), profile: profile)
        _ = await bind(f)
    }
    private func hear(_ f: LastFMFixture, chosenByUser: Bool? = nil) async {
        let occurrence = occurrence()
        await f.coordinator.begin(track: song, occurrence: occurrence, intent: .newListen, expectedScope: f.scope, chosenByUser: chosenByUser)
        for time in 1...61 {
            await f.coordinator.sample(occurrence: occurrence, position: Double(time), duration: 120, ended: false, expectedScope: f.scope,
                                       observedTime: Double(time), observedWallTime: Date(timeIntervalSince1970: 1_700_000_000))
        }
    }
}

private struct LastFMFixture {
    let directory: URL
    let store: LastFMStore
    let secrets: LastFMFakeSecrets
    let transport: LastFMFakeTransport
    let clock: LastFMClock
    let scope = UUID()
    let coordinator: LastFMCoordinator
    init(steps: [LastFMFakeTransport.Step]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LastFMTests-\(UUID().uuidString)")
        self.init(directory: directory, secrets: LastFMFakeSecrets(), transport: LastFMFakeTransport(steps), clock: LastFMClock())
    }
    private init(directory: URL, secrets: LastFMFakeSecrets, transport: LastFMFakeTransport, clock: LastFMClock) {
        self.directory = directory; store = LastFMStore(directory: directory)
        self.secrets = secrets; self.transport = transport; self.clock = clock
        coordinator = LastFMCoordinator(store: store, secrets: secrets, api: .init(transport: transport),
            wallTime: { Date(timeIntervalSince1970: 1_700_000_000 + clock.read()) }, monotonicTime: { clock.read() })
    }
    func restarted() -> Self { .init(directory: directory, secrets: secrets, transport: transport, clock: clock) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
private actor LastFMFakeSecrets: LastFMCredentialsStoring {
    private(set) var values: [String: LastFMSavedCredentials] = [:]
    private(set) var reads = 0
    private var shouldFail = false
    func failWrites(_ value: Bool) { shouldFail = value }
    func read(profile: String) -> LastFMSavedCredentials? { reads += 1; return values[profile] }
    func store(_ credentials: LastFMSavedCredentials, profile: String) throws {
        if shouldFail { throw ScrobbleTokenError.unavailable }; values[profile] = credentials
    }
    func remove(profile: String) { values[profile] = nil }
}
private actor LastFMLBTokenFixture: ScrobbleTokenStoring {
    func read(profile: String) -> String? { nil }
    func store(_ token: String, profile: String) { }
    func remove(profile: String) { }
}
private actor LastFMFakeTransport: ScrobbleHTTPTransport {
    enum Step: Sendable { case response(ScrobbleHTTPResponse), failure, hold }
    private var steps: [Step]
    private(set) var requests: [URLRequest] = []
    private var held: CheckedContinuation<ScrobbleHTTPResponse, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ steps: [Step]) { self.steps = steps }
    func send(_ request: URLRequest) async throws -> ScrobbleHTTPResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }
        switch steps.removeFirst() {
        case let .response(response): return response
        case .failure: throw URLError(.networkConnectionLost)
        case .hold: return await withCheckedContinuation { held = $0; for waiter in waiters { waiter.resume() }; waiters = [] }
        }
    }
    func waitForHold() async { if held == nil { await withCheckedContinuation { waiters.append($0) } } }
    func finish(_ value: ScrobbleHTTPResponse) { held?.resume(returning: value); held = nil }
}
private final class LastFMClock: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0.0
    func set(_ value: Double) { lock.withLock { self.value = value } }
    func read() -> Double { lock.withLock { value } }
}
private func fields(_ request: URLRequest) -> [String: String] {
    let query = request.url?.query ?? String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    return Dictionary(uniqueKeysWithValues: URLComponents(string: "https://fixture.invalid/?" + query)!.queryItems!.map { ($0.name, $0.value ?? "") })
}
private func json(_ object: [String: Any], status: Int = 200) -> ScrobbleHTTPResponse {
    .init(data: try! JSONSerialization.data(withJSONObject: object), statusCode: status)
}
private func tokenResponse() -> ScrobbleHTTPResponse { json(["token": String(repeating: "c", count: 32)]) }
private func sessionResponse(name: String = "fixture-user") -> ScrobbleHTTPResponse {
    json(["session": ["name": name, "key": String(repeating: "d", count: 32), "subscriber": 0]])
}
private func errorResponse(_ code: Int) -> ScrobbleHTTPResponse { json(["error": code, "message": "fixture-error"]) }
private func accepted(ignored: Bool = false, status: Int = 200, timestamp: Int = 1_700_000_000) -> ScrobbleHTTPResponse {
    json(["scrobbles": ["@attr": ["accepted": ignored ? "0" : "1", "ignored": ignored ? "1" : "0"],
        "scrobble": ["ignoredMessage": ["code": ignored ? "1" : "0", "#text": ""], "timestamp": String(timestamp)]]], status: status)
}
