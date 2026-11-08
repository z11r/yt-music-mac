import Darwin
import Foundation

/// Lazy local-only IPC. Constructing this type never opens a socket or reads Discord data.
final class DiscordUnixChannel: DiscordIPCChannel, @unchecked Sendable {
    private final class Handle: @unchecked Sendable {
        let descriptor: Int32
        private let lock = NSLock()
        private var open = true
        private var users = 0
        init(_ descriptor: Int32) { self.descriptor = descriptor }
        func use<T>(_ body: (Int32) throws -> T) throws -> T {
            try lock.withLock {
                guard open else { throw DiscordPresenceError.revoked }
                users += 1
            }
            defer {
                lock.withLock {
                    users -= 1
                    if !open && users == 0 { _ = Darwin.close(descriptor) }
                }
            }
            return try body(descriptor)
        }
        var isOpen: Bool { lock.withLock { open } }
        func close() {
            lock.withLock {
                guard open else { return }
                open = false
                _ = Darwin.shutdown(descriptor, SHUT_RDWR)
                if users == 0 { _ = Darwin.close(descriptor) }
            }
        }
        deinit { close() }
    }
    private let handle: Handle
    private let reads = DispatchQueue(label: "music.discord.ipc.read", qos: .utility)
    private let writes = DispatchQueue(label: "music.discord.ipc.write", qos: .utility)
    private init(handle: Handle) { self.handle = handle }
    func close() { handle.close() }
    deinit { handle.close() }

    static func connect(lease: DiscordPresenceLease, paths: [String]? = nil) async throws -> any DiscordIPCChannel {
        let candidates = paths ?? DiscordIPCPolicy.paths(environment: ProcessInfo.processInfo.environment)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<any DiscordIPCChannel, any Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let deadline = PlaybackOutputTime.monotonic() + 2
                    for path in candidates.prefix(20) {
                        guard lease.isActive else { throw DiscordPresenceError.revoked }
                        guard PlaybackOutputTime.monotonic() < deadline else { throw DiscordPresenceError.timedOut }
                        let bytes = Array(path.utf8)
                        guard path.hasPrefix("/"), !bytes.contains(0), bytes.count < 104 else { continue }
                        var info = stat()
                        guard Darwin.lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
                              info.st_uid == geteuid() else { continue }
                        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                        guard descriptor >= 0 else { continue }
                        let handle = Handle(descriptor)
                        do {
                            try handle.use { descriptor in
                                guard Darwin.fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
                                      Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw DiscordPresenceError.unavailable }
                                var enabled: Int32 = 1
                                guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw DiscordPresenceError.unavailable }
                                var address = sockaddr_un()
                                address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
                                withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                                    pointer.withMemoryRebound(to: UInt8.self, capacity: 104) { target in
                                        bytes.enumerated().forEach { target[$0.offset] = $0.element }
                                        target[bytes.count] = 0
                                    }
                                }
                                let result = withUnsafePointer(to: &address) { pointer in
                                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                                    }
                                }
                                if result != 0 {
                                    guard errno == EINPROGRESS || errno == EAGAIN else { throw DiscordPresenceError.unavailable }
                                    try wait(descriptor, events: Int16(POLLOUT), deadline: deadline, handle: handle, lease: lease)
                                    var error: Int32 = 0; var size = socklen_t(MemoryLayout<Int32>.size)
                                    guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw DiscordPresenceError.unavailable }
                                }
                                var uid: uid_t = 0; var gid: gid_t = 0
                                guard getpeereid(descriptor, &uid, &gid) == 0, uid == geteuid(), lease.isActive else { throw DiscordPresenceError.unavailable }
                            }
                            continuation.resume(returning: DiscordUnixChannel(handle: handle)); return
                        } catch {
                            handle.close()
                            if !lease.isActive { throw DiscordPresenceError.revoked }
                        }
                    }
                    throw DiscordPresenceError.unavailable
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func write(_ frame: DiscordIPCFrame, authorizedBy lease: DiscordPresenceLease?) async throws {
        let data = try frame.encoded()
        try await withTaskCancellationHandler {
            try await perform(on: writes) { [handle] in
                try handle.use { descriptor in
                    let deadline = PlaybackOutputTime.monotonic() + 1
                    var offset = 0
                    do {
                        while offset < data.count {
                            try Self.wait(descriptor, events: Int16(POLLOUT), deadline: deadline, handle: handle, lease: lease)
                            let count: Int
                            func send() -> Int {
                                data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset, MSG_DONTWAIT) }
                            }
                            if let lease { count = try lease.sending { send() } } else { count = send() }
                            if count < 0, errno == EINTR || errno == EAGAIN { continue }
                            guard count > 0 else { throw DiscordPresenceError.unavailable }
                            offset += count
                        }
                    } catch {
                        if offset > 0 { handle.close() } // A partial frame cannot safely be followed by a clear frame.
                        throw error
                    }
                }
            }
        } onCancel: { self.close() }
    }
    func read(timeout: TimeInterval) async throws -> DiscordIPCFrame {
        try await withTaskCancellationHandler {
            try await perform(on: reads) { [handle] in
                try handle.use { descriptor in
                    let deadline = PlaybackOutputTime.monotonic() + min(30, max(0.01, timeout))
                    func exact(_ length: Int) throws -> Data {
                        var data = Data(count: length); var offset = 0
                        while offset < length {
                            try Self.wait(descriptor, events: Int16(POLLIN), deadline: deadline, handle: handle)
                            let count = data.withUnsafeMutableBytes {
                                Darwin.recv(descriptor, $0.baseAddress!.advanced(by: offset), length - offset, MSG_DONTWAIT)
                            }
                            if count < 0, errno == EINTR || errno == EAGAIN { continue }
                            guard count > 0 else { throw DiscordPresenceError.unavailable }
                            offset += count
                        }
                        return data
                    }
                    let header = try DiscordIPCFrame.header(exact(8))
                    return DiscordIPCFrame(opcode: header.opcode, payload: try exact(header.count))
                }
            }
        } onCancel: { self.close() }
    }
    private func perform<T: Sendable>(on queue: DispatchQueue, _ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: operation)) }
        }
    }
    private static func wait(_ descriptor: Int32, events: Int16, deadline: TimeInterval, handle: Handle,
                             lease: DiscordPresenceLease? = nil) throws {
        while true {
            guard handle.isOpen, lease?.isActive != false else { throw DiscordPresenceError.revoked }
            let remaining = deadline - PlaybackOutputTime.monotonic()
            guard remaining > 0 else { throw DiscordPresenceError.timedOut }
            var value = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&value, 1, Int32(min(lease == nil ? 30_000 : 250, ceil(remaining * 1_000))))
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else { throw DiscordPresenceError.unavailable }
            if result == 0 { continue }
            guard value.revents & Int16(POLLERR | POLLNVAL) == 0 else { throw DiscordPresenceError.unavailable }
            if value.revents & events != 0 { return }
            if value.revents & Int16(POLLHUP) != 0 { throw DiscordPresenceError.unavailable }
        }
    }
}
