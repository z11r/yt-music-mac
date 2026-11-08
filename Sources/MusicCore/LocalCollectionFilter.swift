import Foundation

public struct LocalCollectionTag: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

/// Criteria apply only to collection metadata already loaded from the library.
public struct LocalCollectionFilterCriteria: Codable, Equatable, Sendable {
    public enum Scope: String, Codable, Sendable { case loadedLibraryCollections }
    public var scope: Scope
    public var titleContains: String
    public var kind: LocalCollectionReference.Kind?
    public var pinnedOnly: Bool
    public var folderID: UUID?
    public var tagID: UUID?

    public init(scope: Scope = .loadedLibraryCollections, titleContains: String = "",
                kind: LocalCollectionReference.Kind? = nil, pinnedOnly: Bool = false,
                folderID: UUID? = nil, tagID: UUID? = nil) {
        self.scope = scope
        self.titleContains = titleContains
        self.kind = kind
        self.pinnedOnly = pinnedOnly
        self.folderID = folderID
        self.tagID = tagID
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case scope, titleContains, kind, pinnedOnly, folderID, tagID }
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.container(keyedBy: LocalCollectionArchiveKey.self)
        guard Set(raw.allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw LocalCollectionError.invalidFilter
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        scope = try values.decode(Scope.self, forKey: .scope)
        titleContains = try values.decode(String.self, forKey: .titleContains)
        kind = try values.decodeIfPresent(LocalCollectionReference.Kind.self, forKey: .kind)
        pinnedOnly = try values.decode(Bool.self, forKey: .pinnedOnly)
        folderID = try values.decodeIfPresent(UUID.self, forKey: .folderID)
        tagID = try values.decodeIfPresent(UUID.self, forKey: .tagID)
    }

    public func matches(_ reference: LocalCollectionReference, in organization: LocalCollectionOrganization) -> Bool {
        matches(reference, bookmark: organization.bookmarks.first { $0.id == reference.id })
    }

    private func matches(_ reference: LocalCollectionReference, bookmark: LocalCollectionBookmark?) -> Bool {
        guard kind == nil || kind == reference.kind,
              titleContains.isEmpty || reference.title.localizedCaseInsensitiveContains(titleContains) else { return false }
        if pinnedOnly && bookmark?.isPinned != true { return false }
        if let folderID, bookmark?.folderID != folderID { return false }
        if let tagID, bookmark?.tagIDs.contains(tagID) != true { return false }
        return true
    }

    /// Retains loaded order and collapses equivalent playlist browse identifiers.
    public func apply(to loaded: [LocalCollectionReference], in organization: LocalCollectionOrganization) -> [LocalCollectionReference] {
        var seen = Set<String>()
        let bookmarks = Dictionary(organization.bookmarks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return loaded.filter { seen.insert($0.id).inserted && matches($0, bookmark: bookmarks[$0.id]) }
    }
}

struct LocalCollectionArchiveKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

public struct LocalSavedCollectionFilter: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let criteria: LocalCollectionFilterCriteria
    public init(id: UUID = UUID(), name: String, criteria: LocalCollectionFilterCriteria) {
        self.id = id
        self.name = name
        self.criteria = criteria
    }
}
