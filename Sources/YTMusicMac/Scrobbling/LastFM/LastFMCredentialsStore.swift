import Foundation
import Security
import LocalAuthentication

protocol LastFMCredentialsStoring: Sendable {
    func read(profile: String) async throws -> LastFMSavedCredentials?
    func store(_ credentials: LastFMSavedCredentials, profile: String) async throws
    func remove(profile: String) async throws
}

/// Constructing this adapter performs no Keychain operation. Reads/writes occur
/// only for a configured, confirmed profile through the optional feature.
actor KeychainLastFMCredentials: LastFMCredentialsStoring {
    private let service: String
    init(service: String) { self.service = service }
    func read(profile: String) throws -> LastFMSavedCredentials? {
        var query = try query(profile)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 4_096,
              let value = try? JSONDecoder().decode(LastFMSavedCredentials.self, from: data), value.isValid else { throw ScrobbleTokenError.unavailable }
        return value
    }
    func store(_ credentials: LastFMSavedCredentials, profile: String) throws {
        guard credentials.isValid else { throw ScrobbleTokenError.unavailable }
        let query = try query(profile)
        let changes: [CFString: Any] = [kSecValueData: try JSONEncoder().encode(credentials)]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = try JSONEncoder().encode(credentials)
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ScrobbleTokenError.unavailable }
        } else if status != errSecSuccess { throw ScrobbleTokenError.unavailable }
    }
    func remove(profile: String) throws {
        let status = SecItemDelete(try query(profile) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ScrobbleTokenError.unavailable }
    }
    private func query(_ profile: String) throws -> [CFString: Any] {
        guard profile.utf8.count == 64, profile.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ScrobbleTokenError.unavailable }
        return [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: profile, kSecAttrSynchronizable: false]
    }
}
