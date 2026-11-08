import Foundation
import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

private actor ChangingStorageUsageSessions: MusicSessionProviding {
    let first: MusicSession
    let second: MusicSession
    private var read = false
    init(first: MusicSession, second: MusicSession) { self.first = first; self.second = second }
    func snapshot() -> MusicSession { defer { read = true }; return read ? second : first }
}

@MainActor @Suite("Read-only scoped saved-data usage", .serialized)
struct StorageUsageControllerTests {
    private let first = String(repeating: "a", count: 64)
    private let second = String(repeating: "b", count: 64)

    @Test func inventoryMeasuresFixedFilesWithoutChangingTheirContents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageUsageTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [("queue.json", 13), ("SavedQueues/\(first)/queues.json", 27),
                     ("LocalCollections/\(first)/organization.json", 41), ("SavedQueues/\(second)/queues.json", 99),
                     ("credentials-sentinel", 55), ("WebKit/session-sentinel", 71)]
        for (path, count) in files { try write(count, path: path, root: root) }
        let inventory = ProtectedStorageInventory(directoryURL: root)
        let usage = try await inventory.measure(accountKey: first)
        #expect(usage.currentQueueBytes == 13 && usage.namedQueueBytes == 27 && usage.organizationBytes == 41)
        #expect(try await inventory.measure(accountKey: second).namedQueueBytes == 99)
        for (path, count) in files { #expect(try Data(contentsOf: root.appendingPathComponent(path)).count == count) }
        await #expect(throws: NamedQueueError.invalidAccount) { try await inventory.measure(accountKey: "../private") }
    }

    @Test func accountChangesAndStaleUIRequestsCannotExposeAnotherAccountsSizes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageUsageScopeTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try write(17, path: "SavedQueues/\(first)/queues.json", root: root)
        try write(91, path: "SavedQueues/\(second)/queues.json", root: root)
        let sessions = MusicSessionStore()
        await sessions.replaceSession(accountID: first, cookieHeader: "fixture=1", sapisid: "fixture")
        let storage = StorageController(inventory: ProtectedStorageInventory(directoryURL: root), sessions: sessions)
        await storage.refresh(expectedScope: storage.scope)
        #expect(storage.protectedUsage?.namedQueueBytes == 17)
        let oldScope = storage.scope
        storage.invalidate()
        await sessions.replaceSession(accountID: second, cookieHeader: "fixture=1", sapisid: "fixture")
        await storage.refresh(expectedScope: oldScope)
        #expect(storage.protectedUsage == nil)
        await storage.refresh(expectedScope: storage.scope)
        #expect(storage.protectedUsage?.namedQueueBytes == 91)
        await sessions.clear()
        await storage.refresh(expectedScope: storage.scope)
        #expect(storage.protectedUsage == nil && storage.errorMessage != nil)
    }

    @Test func aSessionChangeDuringMeasurementRejectsTheResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageUsageFenceTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try write(53, path: "SavedQueues/\(first)/queues.json", root: root)
        let a = MusicSession(scope: UUID(), accountID: first, cookieHeader: "fixture=1", sapisid: "fixture")
        let b = MusicSession(scope: UUID(), accountID: second, cookieHeader: "fixture=1", sapisid: "fixture")
        let storage = StorageController(inventory: ProtectedStorageInventory(directoryURL: root), sessions: ChangingStorageUsageSessions(first: a, second: b))
        await storage.refresh(expectedScope: storage.scope)
        #expect(storage.protectedUsage == nil && storage.errorMessage != nil && !storage.isWorking)
    }

    @Test func nonRegularSavedDataIsPreservedAndReportedAsUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageUsageFileTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("queue.json"), withIntermediateDirectories: true)
        let inventory = ProtectedStorageInventory(directoryURL: root)
        await #expect(throws: ProtectedStorageInventoryError.self) { try await inventory.measure(accountKey: first) }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("queue.json").path))
    }

    private func write(_ count: Int, path: String, root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: count).write(to: url)
    }
}
