import Foundation

enum DiscordPresenceText {
    static func text(_ key: StaticString) -> String {
        AppLocalization.bundle.localizedString(forKey: String(describing: key), value: nil, table: "DiscordPresence")
    }
}

enum DiscordPresenceError: Error, Equatable, LocalizedError, Sendable {
    case revoked, unavailable, rejected, invalidFrame, timedOut, busy, invalidApplicationID, invalidSettings, unsupportedText
    var errorDescription: String? {
        switch self {
        case .revoked: DiscordPresenceText.text("This presence request is no longer current.")
        case .unavailable: DiscordPresenceText.text("The local Discord client is unavailable. Open Discord and explicitly retry sharing.")
        case .rejected: DiscordPresenceText.text("Discord rejected this presence request. Sharing stopped without requesting credentials or additional permissions.")
        case .invalidFrame: DiscordPresenceText.text("Discord returned an unsupported local response. Sharing stopped.")
        case .timedOut: DiscordPresenceText.text("The local Discord request timed out. Sharing stopped; retry explicitly when ready.")
        case .busy: DiscordPresenceText.text("Wait for the current Discord request to settle.")
        case .invalidApplicationID: DiscordPresenceText.text("Enter the numeric application ID of a Discord application you registered. No application ID or secret is supplied by this app.")
        case .invalidSettings: DiscordPresenceText.text("The saved Discord configuration is unsupported or damaged. It has been kept until explicitly forgotten.")
        case .unsupportedText: DiscordPresenceText.text("The song text exceeds Discord's shared field limits.")
        }
    }
}

/// Only nonblocking send syscalls run inside this lock; connect, poll, reads and acknowledgements never do.
final class DiscordPresenceLease: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { lock.withLock { active } }
    func revoke() { lock.withLock { active = false } }
    func sending<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            guard active else { throw DiscordPresenceError.revoked }
            return try body()
        }
    }
}

struct DiscordIPCFrame: Sendable, Equatable {
    enum Opcode: UInt32, Sendable { case handshake = 0, message = 1, close = 2, ping = 3, pong = 4 }
    static let byteLimit = 16_384
    let opcode: Opcode
    let payload: Data
    func encoded() throws -> Data {
        guard payload.count <= Self.byteLimit else { throw DiscordPresenceError.invalidFrame }
        var output = Data()
        for value in [opcode.rawValue, UInt32(payload.count)] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { output.append(contentsOf: $0) }
        }
        output.append(payload)
        return output
    }
    static func header(_ data: Data) throws -> (opcode: Opcode, count: Int) {
        guard data.count == 8 else { throw DiscordPresenceError.invalidFrame }
        let bytes = Array(data)
        func number(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | (UInt32(bytes[offset + $1]) << ($1 * 8)) } }
        guard let opcode = Opcode(rawValue: number(0)), number(4) <= Self.byteLimit else { throw DiscordPresenceError.invalidFrame }
        return (opcode, Int(number(4)))
    }
    static func json(_ object: [String: Any], opcode: Opcode = .message) throws -> Self {
        let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard payload.count <= Self.byteLimit else { throw DiscordPresenceError.invalidFrame }
        return Self(opcode: opcode, payload: payload)
    }
    func object() throws -> [String: Any] {
        guard payload.count <= Self.byteLimit, let value = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw DiscordPresenceError.invalidFrame
        }
        return value
    }
}

protocol DiscordIPCChannel: AnyObject, Sendable {
    func write(_ frame: DiscordIPCFrame, authorizedBy lease: DiscordPresenceLease?) async throws
    func read(timeout: TimeInterval) async throws -> DiscordIPCFrame
    func close()
}

enum DiscordIPCPolicy {
    static func acceptsApplicationID(_ id: String) -> Bool {
        (17...20).contains(id.utf8.count) && id.utf8.allSatisfy { (48...57).contains($0) } && UInt64(id).map { $0 > 0 } == true
    }
    static func paths(environment: [String: String]) -> [String] {
        let preferred = ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"].compactMap { environment[$0] }.first {
            $0.hasPrefix("/") && !$0.utf8.contains(0) && $0.utf8.count <= 80
        }
        var prefixes = preferred.map { [$0] } ?? []
        if !prefixes.contains("/tmp") { prefixes.append("/tmp") }
        return prefixes.prefix(2).flatMap { prefix in
            (0..<10).map { URL(fileURLWithPath: prefix).appendingPathComponent("discord-ipc-\($0)").path }
        }
    }
}
