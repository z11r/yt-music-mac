import Foundation

public struct LocalCollectionReference: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case playlist, album, artist, podcast }
    public let serviceID: String
    public let kind: Kind
    public let title: String
    public var id: String {
        let canonical = kind == .playlist && serviceID.hasPrefix("VL") ? String(serviceID.dropFirst(2)) : serviceID
        return kind.rawValue + ":" + canonical
    }
    public init(serviceID: String, kind: Kind, title: String) {
        self.serviceID = serviceID
        self.kind = kind
        self.title = title
    }
}

public struct LocalCollectionFolder: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

public struct LocalCollectionBookmark: Identifiable, Codable, Equatable, Sendable {
    public var reference: LocalCollectionReference
    public var isPinned: Bool
    public var folderID: UUID?
    public var tagIDs: Set<UUID>
    public var id: String { reference.id }
    public init(reference: LocalCollectionReference, isPinned: Bool = false, folderID: UUID? = nil, tagIDs: Set<UUID> = []) {
        self.reference = reference
        self.isPinned = isPinned
        self.folderID = folderID
        self.tagIDs = tagIDs
    }

    private enum CodingKeys: String, CodingKey { case reference, isPinned, folderID, tagIDs }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        reference = try values.decode(LocalCollectionReference.self, forKey: .reference)
        isPinned = try values.decode(Bool.self, forKey: .isPinned)
        folderID = try values.decodeIfPresent(UUID.self, forKey: .folderID)
        let tags = try values.decodeIfPresent([UUID].self, forKey: .tagIDs) ?? []
        tagIDs = Set(tags)
        guard tagIDs.count == tags.count else { throw LocalCollectionError.invalidArchive }
    }
}

public struct LocalCollectionOrganization: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public let version: Int
    public var folders: [LocalCollectionFolder]
    public var bookmarks: [LocalCollectionBookmark]
    public var tags: [LocalCollectionTag]
    public var savedFilters: [LocalSavedCollectionFilter]
    public var pinned: [LocalCollectionBookmark] { bookmarks.filter(\.isPinned) }
    public func members(of folderID: UUID) -> [LocalCollectionBookmark] { bookmarks.filter { $0.folderID == folderID } }
    public init(version: Int = currentVersion, folders: [LocalCollectionFolder] = [], bookmarks: [LocalCollectionBookmark] = [],
                tags: [LocalCollectionTag] = [], savedFilters: [LocalSavedCollectionFilter] = []) {
        self.version = version
        self.folders = folders
        self.bookmarks = bookmarks
        self.tags = tags
        self.savedFilters = savedFilters
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case version, folders, bookmarks, tags, savedFilters }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try values.decode(Int.self, forKey: .version)
        guard (1...Self.currentVersion).contains(storedVersion) else { throw LocalCollectionError.unsupportedVersion(storedVersion) }
        let raw = try decoder.container(keyedBy: LocalCollectionArchiveKey.self)
        guard Set(raw.allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else { throw LocalCollectionError.invalidArchive }
        version = Self.currentVersion
        folders = try values.decode([LocalCollectionFolder].self, forKey: .folders)
        bookmarks = try values.decode([LocalCollectionBookmark].self, forKey: .bookmarks)
        tags = storedVersion == 1 ? [] : try values.decode([LocalCollectionTag].self, forKey: .tags)
        savedFilters = storedVersion == 1 ? [] : try values.decode([LocalSavedCollectionFilter].self, forKey: .savedFilters)
    }
}

public enum LocalCollectionError: Error, Equatable, LocalizedError, Sendable {
    case invalidName, duplicateName, missingFolder, missingTag, missingFilter, referencedByFilter
    case invalidFilter, invalidCollection, invalidArchive, fileTooLarge, capacityReached
    case unsupportedVersion(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidName: CoreLocalization.text("Use a name of 1–100 characters without control characters.")
        case .duplicateName: CoreLocalization.text("An item of this type already has this name.")
        case .missingFolder: CoreLocalization.text("This local folder no longer exists. Refresh the list.")
        case .missingTag: CoreLocalization.text("This local tag no longer exists. Refresh the list.")
        case .missingFilter: CoreLocalization.text("This saved filter no longer exists. Refresh the list.")
        case .referencedByFilter: CoreLocalization.text("Update or delete the saved filters using this folder or tag first.")
        case .invalidFilter: CoreLocalization.text("The filter contains unsupported criteria or a title longer than 200 characters.")
        case .invalidCollection: CoreLocalization.text("This collection could not be saved as a local bookmark.")
        case .invalidArchive: CoreLocalization.text("The local collection organization could not be read. The file has been kept.")
        case .fileTooLarge: CoreLocalization.text("The local collection organization exceeds its storage limit.")
        case .capacityReached: CoreLocalization.text("The local collection limit was reached. Remove an unused bookmark or folder first.")
        case let .unsupportedVersion(version): CoreLocalization.format("Local collection organization version %lld is not supported.", version)
        }
    }
}

/// Local organization only. Every operation addresses one already-confirmed account namespace.
public actor LocalCollectionStore {
    private let directoryURL: URL
    private let maximumBytes: Int
    private let maximumFolders: Int
    private let maximumBookmarks: Int
    private let maximumTags: Int
    private let maximumFilters: Int

    public init(directoryURL: URL, maximumBytes: Int = 1024 * 1024,
                maximumFolders: Int = 50, maximumBookmarks: Int = 1_000,
                maximumTags: Int = 50, maximumFilters: Int = 50) {
        self.directoryURL = directoryURL
        self.maximumBytes = max(1, maximumBytes)
        self.maximumFolders = max(1, maximumFolders)
        self.maximumBookmarks = max(1, maximumBookmarks)
        self.maximumTags = max(1, maximumTags)
        self.maximumFilters = max(1, maximumFilters)
    }

    public func load(accountKey: String) throws -> LocalCollectionOrganization {
        let url = try fileURL(accountKey)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw LocalCollectionError.invalidArchive }
            if let bytes = attributes[.size] as? NSNumber, bytes.intValue > maximumBytes { throw LocalCollectionError.fileTooLarge }
            guard let stream = InputStream(url: url) else { throw LocalCollectionError.invalidArchive }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                try Task.checkCancellation()
                let capacity = min(buffer.count, maximumBytes + 1 - data.count)
                guard capacity > 0 else { throw LocalCollectionError.fileTooLarge }
                let count = stream.read(&buffer, maxLength: capacity)
                guard count >= 0 else { throw LocalCollectionError.invalidArchive }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= maximumBytes else { throw LocalCollectionError.fileTooLarge }
            }
            let organization: LocalCollectionOrganization
            do { organization = try JSONDecoder().decode(LocalCollectionOrganization.self, from: data) }
            catch let error as LocalCollectionError { throw error }
            catch { throw LocalCollectionError.invalidArchive }
            try validate(organization)
            return organization
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                    (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return LocalCollectionOrganization()
        }
    }

    @discardableResult public func createFolder(name: String, accountKey: String) throws -> LocalCollectionOrganization {
        var organization = try load(accountKey: accountKey)
        let name = try folderName(name)
        guard organization.folders.count < maximumFolders else { throw LocalCollectionError.capacityReached }
        guard !organization.folders.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw LocalCollectionError.duplicateName
        }
        organization.folders.append(LocalCollectionFolder(name: name))
        return try write(organization, accountKey: accountKey)
    }

    @discardableResult public func renameFolder(id: UUID, name: String, accountKey: String) throws -> LocalCollectionOrganization {
        var organization = try load(accountKey: accountKey)
        let name = try folderName(name)
        guard let index = organization.folders.firstIndex(where: { $0.id == id }) else { throw LocalCollectionError.missingFolder }
        guard !organization.folders.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw LocalCollectionError.duplicateName
        }
        organization.folders[index] = LocalCollectionFolder(id: id, name: name)
        return try write(organization, accountKey: accountKey)
    }

    @discardableResult public func removeFolder(id: UUID, accountKey: String) throws -> LocalCollectionOrganization {
        var organization = try load(accountKey: accountKey)
        guard organization.folders.contains(where: { $0.id == id }) else { throw LocalCollectionError.missingFolder }
        guard !organization.savedFilters.contains(where: { $0.criteria.folderID == id }) else { throw LocalCollectionError.referencedByFilter }
        organization.folders.removeAll { $0.id == id }
        for index in organization.bookmarks.indices where organization.bookmarks[index].folderID == id {
            organization.bookmarks[index].folderID = nil
        }
        organization.bookmarks.removeAll { !$0.isPinned && $0.folderID == nil && $0.tagIDs.isEmpty }
        return try write(organization, accountKey: accountKey)
    }

    @discardableResult public func setPinned(_ pinned: Bool, reference: LocalCollectionReference,
                                            accountKey: String) throws -> LocalCollectionOrganization {
        var organization = try load(accountKey: accountKey)
        if let index = organization.bookmarks.firstIndex(where: { $0.id == reference.id }) {
            organization.bookmarks[index].reference = reference
            organization.bookmarks[index].isPinned = pinned
        } else if pinned {
            organization.bookmarks.append(LocalCollectionBookmark(reference: reference, isPinned: true))
        }
        organization.bookmarks.removeAll { !$0.isPinned && $0.folderID == nil && $0.tagIDs.isEmpty }
        return try write(organization, accountKey: accountKey)
    }

    @discardableResult public func move(_ reference: LocalCollectionReference, to folderID: UUID?,
                                       accountKey: String) throws -> LocalCollectionOrganization {
        var organization = try load(accountKey: accountKey)
        if let folderID, !organization.folders.contains(where: { $0.id == folderID }) { throw LocalCollectionError.missingFolder }
        if let index = organization.bookmarks.firstIndex(where: { $0.id == reference.id }) {
            organization.bookmarks[index].reference = reference
            organization.bookmarks[index].folderID = folderID
        } else if folderID != nil {
            organization.bookmarks.append(LocalCollectionBookmark(reference: reference, folderID: folderID))
        }
        organization.bookmarks.removeAll { !$0.isPinned && $0.folderID == nil && $0.tagIDs.isEmpty }
        return try write(organization, accountKey: accountKey)
    }

    @discardableResult public func saveTag(id: UUID? = nil, name: String, accountKey: String) throws -> LocalCollectionOrganization {
        var organization = try load(accountKey: accountKey)
        let name = try folderName(name)
        guard !organization.tags.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { throw LocalCollectionError.duplicateName }
        let tag = LocalCollectionTag(id: id ?? UUID(), name: name)
        if let id {
            guard let index = organization.tags.firstIndex(where: { $0.id == id }) else { throw LocalCollectionError.missingTag }
            organization.tags[index] = tag
        } else {
            guard organization.tags.count < maximumTags else { throw LocalCollectionError.capacityReached }
            organization.tags.append(tag)
        }
        return try write(organization, accountKey: accountKey)
    }

    @discardableResult public func removeTag(id: UUID, accountKey: String) throws -> LocalCollectionOrganization {
        var organization = try load(accountKey: accountKey)
        guard organization.tags.contains(where: { $0.id == id }) else { throw LocalCollectionError.missingTag }
        guard !organization.savedFilters.contains(where: { $0.criteria.tagID == id }) else { throw LocalCollectionError.referencedByFilter }
        organization.tags.removeAll { $0.id == id }
        for index in organization.bookmarks.indices { organization.bookmarks[index].tagIDs.remove(id) }
        organization.bookmarks.removeAll { !$0.isPinned && $0.folderID == nil && $0.tagIDs.isEmpty }
        return try write(organization, accountKey: accountKey)
    }

    @discardableResult public func setTag(_ tagID: UUID, present: Bool, reference: LocalCollectionReference,
                                        accountKey: String) throws -> LocalCollectionOrganization {
        var organization = try load(accountKey: accountKey)
        guard organization.tags.contains(where: { $0.id == tagID }) else { throw LocalCollectionError.missingTag }
        if let index = organization.bookmarks.firstIndex(where: { $0.id == reference.id }) {
            organization.bookmarks[index].reference = reference
            if present { organization.bookmarks[index].tagIDs.insert(tagID) }
            else { organization.bookmarks[index].tagIDs.remove(tagID) }
        } else if present {
            organization.bookmarks.append(LocalCollectionBookmark(reference: reference, tagIDs: [tagID]))
        }
        organization.bookmarks.removeAll { !$0.isPinned && $0.folderID == nil && $0.tagIDs.isEmpty }
        return try write(organization, accountKey: accountKey)
    }

    @discardableResult public func saveFilter(id: UUID? = nil, name: String, criteria: LocalCollectionFilterCriteria,
                                            accountKey: String) throws -> LocalCollectionOrganization {
        var organization = try load(accountKey: accountKey)
        let name = try folderName(name)
        guard !organization.savedFilters.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { throw LocalCollectionError.duplicateName }
        let filter = LocalSavedCollectionFilter(id: id ?? UUID(), name: name, criteria: criteria)
        if let id {
            guard let index = organization.savedFilters.firstIndex(where: { $0.id == id }) else { throw LocalCollectionError.missingFilter }
            organization.savedFilters[index] = filter
        } else {
            guard organization.savedFilters.count < maximumFilters else { throw LocalCollectionError.capacityReached }
            organization.savedFilters.append(filter)
        }
        return try write(organization, accountKey: accountKey)
    }

    @discardableResult public func removeFilter(id: UUID, accountKey: String) throws -> LocalCollectionOrganization {
        var organization = try load(accountKey: accountKey)
        guard organization.savedFilters.contains(where: { $0.id == id }) else { throw LocalCollectionError.missingFilter }
        organization.savedFilters.removeAll { $0.id == id }
        return try write(organization, accountKey: accountKey)
    }

    private func fileURL(_ accountKey: String) throws -> URL {
        guard directoryURL.isFileURL else { throw QueuePersistenceError.invalidStorageURL }
        guard NamedQueueStore.acceptsAccountKey(accountKey) else { throw NamedQueueError.invalidAccount }
        return directoryURL.appendingPathComponent(accountKey).appendingPathComponent("organization.json")
    }

    private nonisolated func folderName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(name.count), name.utf8.count <= 1_024,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw LocalCollectionError.invalidName }
        return name
    }

    private nonisolated func validate(_ organization: LocalCollectionOrganization) throws {
        guard organization.version == LocalCollectionOrganization.currentVersion else { throw LocalCollectionError.unsupportedVersion(organization.version) }
        guard organization.folders.count <= maximumFolders, organization.bookmarks.count <= maximumBookmarks,
              organization.tags.count <= maximumTags, organization.savedFilters.count <= maximumFilters else { throw LocalCollectionError.capacityReached }
        let folderIDs = Set(organization.folders.map(\.id))
        let tagIDs = Set(organization.tags.map(\.id))
        guard folderIDs.count == organization.folders.count,
              tagIDs.count == organization.tags.count,
              Set(organization.savedFilters.map(\.id)).count == organization.savedFilters.count,
              Set(organization.bookmarks.map(\.id)).count == organization.bookmarks.count else { throw LocalCollectionError.invalidArchive }
        for values in [organization.folders.map(\.name), organization.tags.map(\.name), organization.savedFilters.map(\.name)] {
            var names = Set<String>()
            for name in values {
                guard try folderName(name) == name, names.insert(name.lowercased()).inserted else { throw LocalCollectionError.invalidArchive }
            }
        }
        for filter in organization.savedFilters {
            let criteria = filter.criteria
            guard criteria.titleContains.count <= 200, criteria.titleContains.utf8.count <= 2_048,
                  !criteria.titleContains.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  criteria.folderID.map(folderIDs.contains) ?? true,
                  criteria.tagID.map(tagIDs.contains) ?? true else { throw LocalCollectionError.invalidFilter }
        }
        for bookmark in organization.bookmarks {
            let reference = bookmark.reference
            guard !reference.serviceID.isEmpty, reference.serviceID.utf8.count <= 256,
                  reference.serviceID.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
                  !reference.title.isEmpty, reference.title.utf8.count <= 4_096,
                  !reference.title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  bookmark.folderID.map(folderIDs.contains) ?? true,
                  bookmark.tagIDs.count <= 20, bookmark.tagIDs.isSubset(of: tagIDs),
                  bookmark.isPinned || bookmark.folderID != nil || !bookmark.tagIDs.isEmpty else { throw LocalCollectionError.invalidCollection }
        }
    }

    private func write(_ organization: LocalCollectionOrganization, accountKey: String) throws -> LocalCollectionOrganization {
        try validate(organization)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(organization)
        guard data.count <= maximumBytes else { throw LocalCollectionError.fileTooLarge }
        let url = try fileURL(accountKey)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return organization
    }
    /// Pure format admission for explicit profile cleanup; performs no storage access.
    public nonisolated static func validatedCleanupMetadata(_ data: Data) throws -> Data {
        guard data.count <= 1024 * 1024 else { throw QueuePersistenceError.fileTooLarge }
        let value = try JSONDecoder().decode(LocalCollectionOrganization.self, from: data)
        let validator = LocalCollectionStore(directoryURL: URL(fileURLWithPath: "/"))
        try validator.validate(value)
        return try JSONEncoder().encode(value)
    }

}
