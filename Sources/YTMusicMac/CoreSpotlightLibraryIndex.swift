import CoreSpotlight
import Foundation
import MusicCore
import UniformTypeIdentifiers

/// Constructing the adapter does not contact Spotlight. Only an authorized operation creates the named index.
actor CoreSpotlightLibraryIndex: LibrarySpotlightIndex {
    private let policy: SpotlightCatalogPolicy
    private var searchableIndex: CSSearchableIndex?
    init(namespace: String) { policy = SpotlightCatalogPolicy(namespace: namespace) }

    func index(_ records: [SpotlightCatalogRecord]) async throws {
        guard records.count <= SpotlightCatalogPolicy.batchLimit else { throw IndexError.invalidRecords }
        var items: [CSSearchableItem] = []
        for record in records {
            guard let key = policy.accountKey(in: record.identifier), policy.domain(accountKey: key) == record.domain,
                  let reference = policy.reference(for: record.identifier, accountKey: key),
                  reference.serviceID == record.reference.serviceID, reference.kind == record.reference.kind,
                  record.reference.title.count <= 200,
                  !record.reference.title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  record.expiresAt > Date(), record.expiresAt.timeIntervalSinceNow <= SpotlightCatalogPolicy.lifetime + 60 else {
                throw IndexError.invalidRecords
            }
            let attributes = CSSearchableItemAttributeSet(contentType: .item)
            attributes.title = record.reference.title
            attributes.contentDescription = AppLocalization.format("YouTube Music %@", record.reference.kind.localizedTitle)
            attributes.keywords = ["YT Music", record.reference.kind.rawValue, record.reference.kind.localizedTitle]
            let item = CSSearchableItem(uniqueIdentifier: record.identifier, domainIdentifier: record.domain, attributeSet: attributes)
            item.expirationDate = record.expiresAt
            items.append(item)
        }
        let index = try nativeIndex()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            index.indexSearchableItems(items) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func delete(domain: String) async throws {
        guard policy.owns(domain) else { throw IndexError.invalidDomain }
        let index = try nativeIndex()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            index.deleteSearchableItems(withDomainIdentifiers: [domain]) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func nativeIndex() throws -> CSSearchableIndex {
        guard CSSearchableIndex.isIndexingAvailable() else { throw IndexError.unavailable }
        if let searchableIndex { return searchableIndex }
        let created = CSSearchableIndex(name: policy.namespace + ".catalog")
        searchableIndex = created
        return created
    }

    private enum IndexError: Error { case unavailable, invalidDomain, invalidRecords }
}
