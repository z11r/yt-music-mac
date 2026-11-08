import Foundation
import MusicCore
import Testing
@testable import YTMusicMac

private actor DiscordTestTimeout {
    private var pending: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var fired = false
    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if fired { continuation.resume() }
                else { pending[id] = continuation }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func fire() { fired = true; let values = pending; pending = [:]; values.values.forEach { $0.resume() } }
}

private actor DiscordOpenGate {
    private var paused: CheckedContinuation<any DiscordIPCChannel, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func open() async -> any DiscordIPCChannel { await withCheckedContinuation { paused = $0; waiter?.resume(); waiter = nil } }
    func waitForOpen() async { if paused == nil { await withCheckedContinuation { waiter = $0 } } }
    func release(_ channel: any DiscordIPCChannel) { paused?.resume(returning: channel); paused = nil }
}

private final class DiscordTestChannel: DiscordIPCChannel, @unchecked Sendable {
    enum Mode { case normal, pingBeforeReady, rejectActivity, wrongNonce, silentHandshake, holdActivity }
    private let lock = NSLock()
    private let mode: Mode
    private var frames: [DiscordIPCFrame] = []
    private var reading: CheckedContinuation<DiscordIPCFrame, any Error>?
    private var sent: [DiscordIPCFrame] = []
    private var closed = false
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    init(_ mode: Mode = .normal) { self.mode = mode }
    var writes: [DiscordIPCFrame] { lock.withLock { sent } }
    var isClosed: Bool { lock.withLock { closed } }
    func waitForWrites(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock {
                if sent.count >= count { return true }
                waiters.append((count, continuation)); return false
            }
            if immediate { continuation.resume() }
        }
    }
    func write(_ frame: DiscordIPCFrame, authorizedBy lease: DiscordPresenceLease?) async throws {
        let record = {
            let ready = try self.lock.withLock { () throws -> [CheckedContinuation<Void, Never>] in
                guard !self.closed else { throw DiscordPresenceError.revoked }
                self.sent.append(frame)
                let ready = self.waiters.filter { $0.0 <= self.sent.count }.map(\.1)
                self.waiters.removeAll { $0.0 <= self.sent.count }
                return ready
            }
            ready.forEach { $0.resume() }
        }
        if let lease { try lease.sending(record) } else { try record() }
        if frame.opcode == .handshake {
            if mode == .silentHandshake { return }
            if mode == .pingBeforeReady { push(DiscordIPCFrame(opcode: .ping, payload: Data("ping".utf8))) }
            push(try DiscordIPCFrame.json(["cmd": "DISPATCH", "evt": "READY", "data": ["v": 1,
                "user": ["username": "synthetic private name", "id": "synthetic-private-id"]]]))
        } else if frame.opcode == .message {
            let object = try frame.object()
            let nonce = object["nonce"] as? String ?? ""
            let activity = (object["args"] as? [String: Any])?["activity"]
            if mode == .holdActivity, activity != nil { return }
            if mode == .rejectActivity {
                push(try DiscordIPCFrame.json(["cmd": "SET_ACTIVITY", "nonce": nonce, "evt": "ERROR",
                    "data": ["code": 4006, "message": "synthetic private raw payload secret"]]))
            } else {
                push(try DiscordIPCFrame.json(["cmd": "SET_ACTIVITY", "nonce": mode == .wrongNonce ? "wrong-nonce" : nonce,
                    "evt": NSNull(), "data": NSNull()]))
            }
        }
    }
    func acknowledgeLastActivity() throws {
        let frame = try #require(writes.last)
        let object = try frame.object()
        push(try DiscordIPCFrame.json(["cmd": "SET_ACTIVITY", "nonce": object["nonce"] as? String ?? "", "evt": NSNull(), "data": NSNull()]))
    }
    func push(_ frame: DiscordIPCFrame) {
        let continuation = lock.withLock { () -> CheckedContinuation<DiscordIPCFrame, any Error>? in
            guard !closed else { return nil }
            if let reading { self.reading = nil; return reading }
            frames.append(frame); return nil
        }
        continuation?.resume(returning: frame)
    }
    func read(timeout: TimeInterval) async throws -> DiscordIPCFrame {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result: Result<DiscordIPCFrame, any Error>? = lock.withLock {
                    if closed { return .failure(DiscordPresenceError.revoked) }
                    if !frames.isEmpty { return .success(frames.removeFirst()) }
                    if reading != nil { return .failure(DiscordPresenceError.busy) }
                    reading = continuation; return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: { self.close() }
    }
    func close() {
        let continuation = lock.withLock { () -> CheckedContinuation<DiscordIPCFrame, any Error>? in
            closed = true; let value = reading; reading = nil; frames = []; return value
        }
        continuation?.resume(throwing: DiscordPresenceError.revoked)
    }
}

@Suite("Bounded local Discord IPC client")
struct DiscordIPCClientTests {
    private let applicationID = "100000000000000001"
    private var metadata: PublicPlaybackMetadata {
        PublicPlaybackMetadata(track: Track(id: "abcDEF12_-3", title: "Song", artist: "Artist",
            artworkURL: URL(string: "https://example.invalid/private?token=synthetic"), origin: .catalog, contentKind: .song))!
    }
    @Test func frameEncodingIsLittleEndianAndRejectsLengthsBeforePayloadAllocation() throws {
        let frame = DiscordIPCFrame(opcode: .message, payload: Data([1, 2, 3]))
        #expect(try Array(frame.encoded()) == [1, 0, 0, 0, 3, 0, 0, 0, 1, 2, 3])
        #expect(try DiscordIPCFrame.header(Data([1, 0, 0, 0, 3, 0, 0, 0])).count == 3)
        for header in [Data([9, 0, 0, 0, 0, 0, 0, 0]), Data([1, 0, 0, 0, 255, 255, 255, 255]), Data(repeating: 0, count: 7)] {
            #expect(throws: DiscordPresenceError.invalidFrame) { try DiscordIPCFrame.header(header) }
        }
        #expect(throws: DiscordPresenceError.invalidFrame) {
            try DiscordIPCFrame(opcode: .message, payload: Data(repeating: 32, count: 16_385)).encoded()
        }
        #expect(throws: DiscordPresenceError.invalidFrame) { try DiscordIPCFrame(opcode: .message, payload: Data("not json".utf8)).object() }
    }
    @Test func applicationAndCandidatePathValidationIsBoundedAndRequiresNoEnvironmentOrSockets() {
        for value in ["", "1", "secret", "10000000000000000/", "000000000000000000", "999999999999999999999"] {
            #expect(!DiscordIPCPolicy.acceptsApplicationID(value))
        }
        #expect(DiscordIPCPolicy.acceptsApplicationID(applicationID))
        let paths = DiscordIPCPolicy.paths(environment: ["XDG_RUNTIME_DIR": "/synthetic/runtime", "TMPDIR": "/synthetic/temp"])
        #expect(paths.count == 20 && paths[0] == "/synthetic/runtime/discord-ipc-0" && paths[19] == "/tmp/discord-ipc-9")
        #expect(DiscordIPCPolicy.paths(environment: ["TMPDIR": "/tmp"]).count == 10)
        #expect(DiscordIPCPolicy.paths(environment: ["TMPDIR": "relative"]).first == "/tmp/discord-ipc-0")
    }
    @Test func handshakePingPresenceAndClearUseOnlyWhitelistedRoutingAndPublicText() async throws {
        let channel = DiscordTestChannel(.pingBeforeReady)
        let client = DiscordPresenceClient(processID: 123, open: { _ in channel })
        let lease = DiscordPresenceLease()
        try await client.publish(metadata, applicationID: applicationID, lease: lease)
        let wrongLease = DiscordPresenceLease()
        #expect(await client.clear(lease: wrongLease) == .notConnected)
        #expect(!channel.isClosed)
        #expect(await client.clear(lease: lease) == .confirmed)
        #expect(channel.isClosed)
        let frames = channel.writes
        #expect(frames.map(\.opcode) == [.handshake, .pong, .message, .message])
        let handshake = try frames[0].object()
        #expect(Set(handshake.keys) == ["v", "client_id"] && handshake["client_id"] as? String == applicationID)
        let activity = try frames[2].object()
        let args = try #require(activity["args"] as? [String: Any])
        let text = try #require(args["activity"] as? [String: Any])
        #expect(Set(text.keys) == ["type", "details", "state"])
        #expect(text["type"] as? Int == 2 && text["details"] as? String == "Song" && text["state"] as? String == "Artist")
        let clear = try frames[3].object()
        let clearArgs = try #require(clear["args"] as? [String: Any])
        #expect(Set(clearArgs.keys) == ["pid"])
        let serialized = String(decoding: frames.reduce(into: Data()) { $0.append($1.payload) }, as: UTF8.self)
        for omitted in ["AUTHORIZE", "AUTHENTICATE", "private", "token", "abcDEF12_-3", "artwork", "cookie"] { #expect(!serialized.contains(omitted)) }
    }
    @Test func errorsNeverEscalateAuthenticationOrExposeProviderPayloads() async throws {
        let channel = DiscordTestChannel(.rejectActivity)
        let client = DiscordPresenceClient(processID: 123, open: { _ in channel })
        let lease = DiscordPresenceLease()
        do { try await client.publish(metadata, applicationID: applicationID, lease: lease); Issue.record("Expected rejection") }
        catch {
            #expect(error as? DiscordPresenceError == .rejected)
            #expect(!error.localizedDescription.contains("synthetic private raw payload secret"))
        }
        #expect(await client.clear(lease: lease) == .unconfirmed)
        #expect(channel.isClosed)
        #expect(try channel.writes.filter { $0.opcode == .message }.allSatisfy { try $0.object()["cmd"] as? String == "SET_ACTIVITY" })
    }
    @Test func handshakeAndWrongNonceTimeoutsCloseWithoutAutomaticReconnect() async throws {
        for mode in [DiscordTestChannel.Mode.silentHandshake, .wrongNonce] {
            let channel = DiscordTestChannel(mode); let timer = DiscordTestTimeout()
            let client = DiscordPresenceClient(processID: 123, open: { _ in channel }, sleep: timer.sleep)
            let lease = DiscordPresenceLease()
            let task = Task { try await client.publish(metadata, applicationID: applicationID, lease: lease) }
            await channel.waitForWrites(mode == .silentHandshake ? 1 : 2)
            await timer.fire()
            do { try await task.value; Issue.record("Expected timeout") }
            catch { #expect(error as? DiscordPresenceError == .timedOut) }
            #expect(channel.isClosed)
            let count = channel.writes.count
            #expect(await client.clear(lease: lease) == .notConnected)
            #expect(channel.writes.count == count)
        }
    }
    @Test func aFullyAdmittedWriteSettlesBeforeItsOriginalLeaseClear() async throws {
        let channel = DiscordTestChannel(.holdActivity)
        let client = DiscordPresenceClient(processID: 123, open: { _ in channel })
        let lease = DiscordPresenceLease()
        let task = Task { try await client.publish(metadata, applicationID: applicationID, lease: lease) }
        await channel.waitForWrites(2); lease.revoke(); try channel.acknowledgeLastActivity()
        do { try await task.value; Issue.record("Expected revoked lease") }
        catch { #expect(error as? DiscordPresenceError == .revoked) }
        #expect(await client.clear(lease: lease) == .confirmed)
        #expect(channel.isClosed && channel.writes.count == 3)
    }
    @Test func revokedLeasesAndInvalidApplicationIDsNeverOpenOrSend() async throws {
        let channel = DiscordTestChannel()
        let client = DiscordPresenceClient(open: { _ in Issue.record("No connection should be attempted"); return channel })
        let lease = DiscordPresenceLease(); lease.revoke()
        await #expect(throws: DiscordPresenceError.revoked) { try await client.publish(metadata, applicationID: applicationID, lease: lease) }
        await #expect(throws: DiscordPresenceError.invalidApplicationID) { try await client.publish(metadata, applicationID: "bad", lease: DiscordPresenceLease()) }
        let longText = try #require(PublicPlaybackMetadata(track: Track(id: "abcDEF12_-3", title: String(repeating: "曲", count: 60),
            artist: "Artist", origin: .catalog, contentKind: .song)))
        await #expect(throws: DiscordPresenceError.unsupportedText) { try await client.publish(longText, applicationID: applicationID, lease: DiscordPresenceLease()) }
        #expect(channel.writes.isEmpty)
    }
    @Test func aLateConnectionCannotSendItsHandshakeAfterRevocation() async throws {
        let gate = DiscordOpenGate(); let channel = DiscordTestChannel()
        let client = DiscordPresenceClient(open: { _ in await gate.open() })
        let lease = DiscordPresenceLease()
        let publishing = Task { try await client.publish(metadata, applicationID: applicationID, lease: lease) }
        await gate.waitForOpen(); lease.revoke(); await gate.release(channel)
        do { try await publishing.value; Issue.record("Expected revoked late connection") }
        catch { #expect(error as? DiscordPresenceError == .revoked) }
        #expect(channel.isClosed && channel.writes.isEmpty)
    }
    @Test func futureReadyVersionsAndFloodedControlFramesCloseTheStream() async throws {
        for futureVersion in [false, true] {
            let channel = DiscordTestChannel(.silentHandshake)
            let client = DiscordPresenceClient(open: { _ in channel })
            let publishing = Task { try await client.publish(metadata, applicationID: applicationID, lease: DiscordPresenceLease()) }
            await channel.waitForWrites(1)
            if futureVersion {
                channel.push(try DiscordIPCFrame.json(["cmd": "DISPATCH", "evt": "READY", "data": ["v": 99]]))
            } else {
                for _ in 0..<33 { channel.push(DiscordIPCFrame(opcode: .pong, payload: Data())) }
            }
            do { try await publishing.value; Issue.record("Expected unsupported protocol") }
            catch { #expect(error as? DiscordPresenceError == .invalidFrame) }
            #expect(channel.isClosed && channel.writes.count == 1)
        }
    }
}
