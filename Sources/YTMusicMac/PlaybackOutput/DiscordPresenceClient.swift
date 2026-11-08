import Darwin
import Foundation

protocol DiscordPresenceProviding: Sendable {
    func publish(_ metadata: PublicPlaybackMetadata, applicationID: String, lease: DiscordPresenceLease) async throws
    func clear(lease: DiscordPresenceLease) async -> DiscordPresenceClearResult
}
enum DiscordPresenceClearResult: Equatable, Sendable { case notConnected, confirmed, unconfirmed }

/// Uses only a local handshake, SET_ACTIVITY and PONG. It never performs Discord OAuth or general RPC.
actor DiscordPresenceClient: DiscordPresenceProviding {
    private let open: @Sendable (DiscordPresenceLease) async throws -> any DiscordIPCChannel
    private let sleep: @Sendable (Duration) async throws -> Void
    private let monotonic: @Sendable () -> TimeInterval
    private let processID: Int32
    private var channel: (any DiscordIPCChannel)?
    private var connectionID = UUID()
    private var owner: UUID?
    private var applicationID: String?
    private var reader: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var connecting = false
    private var pending: Pending?
    private var frameWindow: TimeInterval = 0
    private var frames = 0
    private struct Pending {
        enum Expected { case ready, activity(String) }
        let id = UUID()
        let expected: Expected
        let continuation: CheckedContinuation<Void, any Error>
    }

    init(processID: Int32 = getpid(),
         open: @escaping @Sendable (DiscordPresenceLease) async throws -> any DiscordIPCChannel = { try await DiscordUnixChannel.connect(lease: $0) },
         monotonic: @escaping @Sendable () -> TimeInterval = PlaybackOutputTime.monotonic,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.processID = processID; self.open = open; self.monotonic = monotonic; self.sleep = sleep
    }
    func publish(_ metadata: PublicPlaybackMetadata, applicationID: String, lease: DiscordPresenceLease) async throws {
        guard DiscordIPCPolicy.acceptsApplicationID(applicationID) else { throw DiscordPresenceError.invalidApplicationID }
        guard metadata.title.utf8.count <= 128, metadata.artist.utf8.count <= 128 else { throw DiscordPresenceError.unsupportedText }
        guard lease.isActive, !Task.isCancelled else { throw DiscordPresenceError.revoked }
        guard !connecting, pending == nil else { throw DiscordPresenceError.busy }
        if owner != lease.id || self.applicationID != applicationID { disconnect(error: .revoked) }
        if channel == nil {
            connecting = true
            let opened: any DiscordIPCChannel
            do { opened = try await open(lease) }
            catch { connecting = false; throw error }
            connecting = false
            guard lease.isActive, !Task.isCancelled else { opened.close(); throw DiscordPresenceError.revoked }
            channel = opened; connectionID = UUID(); owner = lease.id; self.applicationID = applicationID
            frameWindow = monotonic(); frames = 0
            startReader(opened, id: connectionID)
            do {
                let handshake = try DiscordIPCFrame.json(["v": 1, "client_id": applicationID], opcode: .handshake)
                try await exchange(handshake, expected: .ready, authorization: lease)
            } catch { disconnect(error: Self.safe(error)); throw error }
        }
        guard lease.isActive, owner == lease.id else { throw DiscordPresenceError.revoked }
        let nonce = UUID().uuidString
        let frame = try DiscordIPCFrame.json(["cmd": "SET_ACTIVITY", "nonce": nonce, "args": ["pid": processID,
            "activity": ["type": 2, "details": metadata.title, "state": metadata.artist]]])
        try await exchange(frame, expected: .activity(nonce), authorization: lease)
        guard lease.isActive else { throw DiscordPresenceError.revoked }
    }
    func clear(lease: DiscordPresenceLease) async -> DiscordPresenceClearResult {
        guard owner == lease.id, channel != nil else { return .notConnected }
        lease.revoke()
        var result = DiscordPresenceClearResult.unconfirmed
        if pending == nil, !connecting {
            do {
                let nonce = UUID().uuidString
                // Discord's own ClearPresence serializes SET_ACTIVITY with this process ID and no activity.
                let frame = try DiscordIPCFrame.json(["cmd": "SET_ACTIVITY", "nonce": nonce, "args": ["pid": processID]])
                try await exchange(frame, expected: .activity(nonce), authorization: nil)
                result = .confirmed
            } catch { }
        }
        if owner == lease.id { disconnect(error: .revoked) }
        return result
    }
    private func startReader(_ channel: any DiscordIPCChannel, id: UUID) {
        reader = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let frame = try await channel.read(timeout: 30)
                    guard let self else { channel.close(); return }
                    try await self.receive(frame, connection: id)
                } catch {
                    await self?.readFailed(error, connection: id)
                    return
                }
            }
        }
    }
    private func receive(_ frame: DiscordIPCFrame, connection: UUID) async throws {
        guard connectionID == connection, let channel else { return }
        let now = monotonic()
        if now - frameWindow >= 10 { frameWindow = now; frames = 0 }
        frames += 1
        guard frames <= 32, frame.payload.count <= DiscordIPCFrame.byteLimit else { throw DiscordPresenceError.invalidFrame }
        if frame.opcode == .ping {
            try await channel.write(DiscordIPCFrame(opcode: .pong, payload: frame.payload), authorizedBy: nil)
            return
        }
        if frame.opcode == .pong { return }
        guard frame.opcode == .message else { throw DiscordPresenceError.invalidFrame }
        let object = try frame.object()
        guard let pending else { return } // No subscription or user data is retained.
        switch pending.expected {
        case .ready:
            if object["evt"] as? String == "ERROR" { finish(pending.id, result: .failure(DiscordPresenceError.rejected)); return }
            guard object["cmd"] as? String == "DISPATCH", object["evt"] as? String == "READY" else { return }
            guard (object["data"] as? [String: Any])?["v"] as? Int == 1 else { throw DiscordPresenceError.invalidFrame }
        case let .activity(nonce):
            guard object["nonce"] as? String == nonce, object["cmd"] as? String == "SET_ACTIVITY" else { return }
            if object["evt"] as? String == "ERROR" { finish(pending.id, result: .failure(DiscordPresenceError.rejected)); return }
            guard object["evt"] == nil || object["evt"] is NSNull else { throw DiscordPresenceError.invalidFrame }
        }
        finish(pending.id, result: .success(()))
    }
    private func exchange(_ frame: DiscordIPCFrame, expected: Pending.Expected, authorization: DiscordPresenceLease?) async throws {
        guard pending == nil, let channel else { throw DiscordPresenceError.busy }
        let connection = connectionID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let request = Pending(expected: expected, continuation: continuation)
                pending = request
                timeout = Task { [weak self, sleep] in
                    do { try await sleep(.seconds(2)) } catch { return }
                    await self?.expired(request.id, connection: connection)
                }
                sender = Task { [weak self] in
                    do { try await channel.write(frame, authorizedBy: authorization) }
                    catch { await self?.sendFailed(error, request: request.id, connection: connection) }
                }
            }
        } onCancel: { Task { await self.cancel(connection: connection) } }
    }
    private func finish(_ id: UUID, result: Result<Void, any Error>) {
        guard let pending, pending.id == id else { return }
        self.pending = nil; timeout?.cancel(); timeout = nil
        pending.continuation.resume(with: result)
    }
    private func expired(_ request: UUID, connection: UUID) {
        guard connectionID == connection, pending?.id == request else { return }
        disconnect(error: .timedOut)
    }
    private func sendFailed(_ error: any Error, request: UUID, connection: UUID) {
        guard connectionID == connection, pending?.id == request else { return }
        // Keep a stream with no partially written frame available for the original lease's clear.
        if (error as? DiscordPresenceError) == .revoked { finish(request, result: .failure(DiscordPresenceError.revoked)) }
        else { disconnect(error: Self.safe(error)) }
    }
    private func readFailed(_ error: any Error, connection: UUID) {
        guard connectionID == connection else { return }
        disconnect(error: Self.safe(error))
    }
    private func cancel(connection: UUID) { if connectionID == connection { disconnect(error: .revoked) } }
    private func disconnect(error: DiscordPresenceError) {
        let old = channel
        channel = nil; owner = nil; applicationID = nil; connectionID = UUID()
        old?.close(); reader?.cancel(); reader = nil; sender?.cancel(); sender = nil; timeout?.cancel(); timeout = nil
        if let pending { self.pending = nil; pending.continuation.resume(throwing: error) }
    }
    private static func safe(_ error: any Error) -> DiscordPresenceError { error as? DiscordPresenceError ?? .unavailable }
}
