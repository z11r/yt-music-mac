import Foundation

public struct SpotlightCatalogRecord: Equatable, Sendable {
    public let identifier: String
    public let domain: String
    public let reference: LocalCollectionReference
    public let expiresAt: Date
}

/// Versioned opaque item identifiers contain only a confirmed account hash and catalog identity.
public struct SpotlightCatalogPolicy: Sendable {
    public static let recordLimit = 500
    public static let batchLimit = 100
    public static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    public let namespace: String
    public var rootDomain: String { namespace + ".library" }

    public init(namespace: String) { self.namespace = namespace }

    public func domain(accountKey: String) -> String? {
        guard validNamespace, NamedQueueStore.acceptsAccountKey(accountKey) else { return nil }
        return rootDomain + "." + accountKey
    }

    public func owns(_ domain: String) -> Bool {
        guard validNamespace else { return false }
        if domain == rootDomain { return true }
        let prefix = rootDomain + "."
        return domain.hasPrefix(prefix) && NamedQueueStore.acceptsAccountKey(String(domain.dropFirst(prefix.count)))
    }

    public func records<Loaded: Sequence>(from loaded: Loaded, accountKey: String, now: Date) -> [SpotlightCatalogRecord]
        where Loaded.Element == LocalCollectionReference {
        guard let domain = domain(accountKey: accountKey), now.timeIntervalSinceReferenceDate.isFinite else { return [] }
        var seen = Set<String>()
        var records: [SpotlightCatalogRecord] = []
        for reference in loaded {
            guard let reference = canonical(reference), seen.insert(reference.id).inserted else { continue }
            records.append(SpotlightCatalogRecord(identifier: domain + "|v1|" + reference.kind.rawValue + "|" + reference.serviceID,
                domain: domain, reference: reference, expiresAt: now.addingTimeInterval(Self.lifetime)))
            if records.count == Self.recordLimit { break }
        }
        return records
    }

    public func reference(for identifier: String, accountKey: String) -> LocalCollectionReference? {
        guard identifier.utf8.count <= 512, let domain = domain(accountKey: accountKey) else { return nil }
        let parts = identifier.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == domain, parts[1] == "v1",
              let kind = LocalCollectionReference.Kind(rawValue: String(parts[2])) else { return nil }
        let title = switch kind { case .playlist: CoreLocalization.text("Playlist"); case .album: CoreLocalization.text("Album"); case .artist: CoreLocalization.text("Artist"); case .podcast: CoreLocalization.text("Podcast") }
        let reference = LocalCollectionReference(serviceID: String(parts[3]), kind: kind, title: title)
        guard let canonical = canonical(reference), canonical.serviceID == reference.serviceID else { return nil }
        return canonical
    }

    public func accountKey(in identifier: String) -> String? {
        guard identifier.utf8.count <= 512 else { return nil }
        let parts = identifier.split(separator: "|", omittingEmptySubsequences: false)
        let prefix = rootDomain + "."
        guard parts.count == 4, parts[0].hasPrefix(prefix) else { return nil }
        let key = String(parts[0].dropFirst(prefix.count))
        return reference(for: identifier, accountKey: key) == nil ? nil : key
    }

    private var validNamespace: Bool {
        !namespace.isEmpty && namespace.utf8.count <= 160 && namespace.contains(".") &&
        namespace.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 }
    }

    private func canonical(_ value: LocalCollectionReference) -> LocalCollectionReference? {
        let id = value.kind == .playlist && value.serviceID.hasPrefix("VL") ? String(value.serviceID.dropFirst(2)) : value.serviceID
        guard (3...256).contains(id.utf8.count),
              id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        // Private/upload browse routes and unknown identifiers cannot enter the OS index.
        let catalog = switch value.kind {
        case .playlist: id.hasPrefix("PL")
        case .album: id.hasPrefix("MPREb_") && id.count > "MPREb_".count
        case .artist: id.hasPrefix("UC")
        case .podcast: false
        }
        guard catalog else { return nil }
        return LocalCollectionReference(serviceID: id, kind: value.kind, title: String(value.title.prefix(200)))
    }
}
