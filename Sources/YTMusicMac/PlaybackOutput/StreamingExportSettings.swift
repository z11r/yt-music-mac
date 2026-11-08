import Foundation
import MusicCore

enum StreamingExportText {
    static func text(_ key: StaticString) -> String {
        AppLocalization.bundle.localizedString(forKey: String(describing: key), value: nil, table: "StreamingExport")
    }
}

@MainActor
struct StreamingExportSettings {
    let preferences: UserDefaults
    let profileNamespace: String
    private struct Record: Codable {
        let version: Int
        let profileNamespace: String
        let accountKey: String
        let receipt: StreamingExportReceipt
    }
    private func key(_ account: String) throws -> String {
        guard NamedQueueStore.acceptsAccountKey(account), !profileNamespace.isEmpty, profileNamespace.utf8.count <= 256 else { throw StreamingExportError.unsupportedSettings }
        return "streamingMetadataTarget.v1." + account
    }
    func load(account: String) throws -> StreamingExportReceipt? {
        let storageKey = try key(account)
        guard let object = preferences.object(forKey: storageKey) else { return nil }
        guard let data = object as? Data, data.count <= 16_384,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(raw.keys) == ["version", "profileNamespace", "accountKey", "receipt"],
              let receiptObject = raw["receipt"] as? [String: Any],
              Set(receiptObject.keys) == ["id", "path", "format", "parent", "file", "digest", "revision"],
              ["parent", "file"].allSatisfy({
                  guard let identity = receiptObject[$0] as? [String: Any] else { return false }
                  return Set(identity.keys) == ["device", "inode"]
              }), let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == 1, record.profileNamespace == profileNamespace, record.accountKey == account else { throw StreamingExportError.unsupportedSettings }
        try record.receipt.validate()
        return record.receipt
    }
    func create(_ receipt: StreamingExportReceipt, account: String) throws {
        guard try load(account: account) == nil else { throw StreamingExportError.changedTarget }
        try save(receipt, account: account)
    }
    func update(_ receipt: StreamingExportReceipt, account: String) throws {
        guard let existing = try load(account: account), existing.id == receipt.id else { return }
        guard receipt.revision >= existing.revision else { return }
        try save(receipt, account: account)
    }
    func forget(account: String) throws { preferences.removeObject(forKey: try key(account)) }
    private func save(_ receipt: StreamingExportReceipt, account: String) throws {
        try receipt.validate()
        let data = try JSONEncoder().encode(Record(version: 1, profileNamespace: profileNamespace, accountKey: account, receipt: receipt))
        guard data.count <= 16_384 else { throw StreamingExportError.tooLarge }
        preferences.set(data, forKey: try key(account))
    }
}
