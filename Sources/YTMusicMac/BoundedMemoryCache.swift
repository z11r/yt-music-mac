import Foundation

struct MemoryCacheUsage: Equatable, Sendable {
    let bytes: Int
    let count: Int
}

/// A small, strictly cost-bounded LRU cache with synchronous, thread-safe reads.
final class BoundedMemoryCache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private struct Entry { let value: Value; let cost: Int; var access: UInt64 }
    private let lock = NSLock()
    private let byteLimit: Int
    private let countLimit: Int
    private var entries: [Key: Entry] = [:]
    private var bytes = 0
    private var access: UInt64 = 0
    private var pressure: (any DispatchSourceMemoryPressure)?

    init(byteLimit: Int, countLimit: Int, observesMemoryPressure: Bool = false) {
        self.byteLimit = max(1, byteLimit)
        self.countLimit = max(1, countLimit)
        if observesMemoryPressure {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in self?.removeAll() }
            pressure = source
            source.resume()
        }
    }

    deinit { pressure?.cancel() }

    func value(for key: Key) -> Value? {
        lock.withLock {
            guard var entry = entries[key] else { return nil }
            access &+= 1
            entry.access = access
            entries[key] = entry
            return entry.value
        }
    }

    func insert(_ value: Value, for key: Key, cost: Int) {
        lock.withLock {
            guard cost >= 0, cost <= byteLimit else { return }
            if let previous = entries.removeValue(forKey: key) { bytes -= previous.cost }
            while entries.count >= countLimit || bytes > byteLimit - cost {
                guard let oldest = entries.min(by: { $0.value.access < $1.value.access }) else { break }
                bytes -= oldest.value.cost
                entries.removeValue(forKey: oldest.key)
            }
            access &+= 1
            entries[key] = Entry(value: value, cost: cost, access: access)
            bytes += cost
        }
    }

    func usage() -> MemoryCacheUsage { lock.withLock { MemoryCacheUsage(bytes: bytes, count: entries.count) } }
    func removeAll() { lock.withLock { entries.removeAll(); bytes = 0 } }
}
