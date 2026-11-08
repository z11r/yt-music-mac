import Foundation

public struct LocalCollectionReference: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case playlist, album, artist }
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
    public var id: String { reference.id }
    public init(reference: LocalCollectionReference, isPinned: Bool = false, folderID: UUID? = nil) {
        self.reference = reference
        self.isPinned = isPinned
        self.folderID = folderID
    }
}

public struct LocalCollectionOrganization: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public var folders: [LocalCollectionFolder]
    public var bookmarks: [LocalCollectionBookmark]
    public var pinned: [LocalCollectionBookmark] { bookmarks.filter(\.isPinned) }
    public func members(of folderID: UUID) -> [LocalCollectionBookmark] { bookmarks.filter { $0.folderID == folderID } }
    public init(version: Int = currentVersion, folders: [LocalCollectionFolder] = [], bookmarks: [LocalCollectionBookmark] = []) {
        self.version = version
        self.folders = folders
        self.bookmarks = bookmarks
    }
}

public enum LocalCollectionError: Error, Equatable, LocalizedError, Sendable {
    case invalidName, duplicateName, missingFolder, invalidCollection, invalidArchive, fileTooLarge, capacityReached
    case unsupportedVersion(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidName: "Use a local folder name of 1–100 characters without control characters."
        case .duplicateName: "A local folder already has this name."
        case .missingFolder: "This local folder no longer exists. Refresh the list."
        case .invalidCollection: "This collection could not be saved as a local bookmark."
        case .invalidArchive: "The local collection organization could not be read. The file has been kept."
        case .fileTooLarge: "The local collection organization exceeds its storage limit."
        case .capacityReached: "The local collection limit was reached. Remove an unused bookmark or folder first."
        case let .unsupportedVersion(version): "Local collection organization version \(version) is not supported."
        }
    }
}

/// Local organization only. Every operation addresses one already-confirmed account namespace.
public actor LocalCollectionStore {
    private let directoryURL: URL
    private let maximumBytes: Int
    private let maximumFolders: Int
    private let maximumBookmarks: Int

    public init(directoryURL: URL, maximumBytes: Int = 1024 * 1024,
                maximumFolders: Int = 50, maximumBookmarks: Int = 1_000) {
        self.directoryURL = directoryURL
        self.maximumBytes = max(1, maximumBytes)
        self.maximumFolders = max(1, maximumFolders)
        self.maximumBookmarks = max(1, maximumBookmarks)
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
        organization.folders.removeAll { $0.id == id }
        for index in organization.bookmarks.indices where organization.bookmarks[index].folderID == id {
            organization.bookmarks[index].folderID = nil
        }
        organization.bookmarks.removeAll { !$0.isPinned && $0.folderID == nil }
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
        organization.bookmarks.removeAll { !$0.isPinned && $0.folderID == nil }
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
        organization.bookmarks.removeAll { !$0.isPinned && $0.folderID == nil }
        return try write(organization, accountKey: accountKey)
    }

    private func fileURL(_ accountKey: String) throws -> URL {
        guard directoryURL.isFileURL else { throw QueuePersistenceError.invalidStorageURL }
        guard NamedQueueStore.acceptsAccountKey(accountKey) else { throw NamedQueueError.invalidAccount }
        return directoryURL.appendingPathComponent(accountKey).appendingPathComponent("organization.json")
    }

    private func folderName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(name.count), name.utf8.count <= 1_024,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw LocalCollectionError.invalidName }
        return name
    }

    private func validate(_ organization: LocalCollectionOrganization) throws {
        guard organization.version == LocalCollectionOrganization.currentVersion else { throw LocalCollectionError.unsupportedVersion(organization.version) }
        guard organization.folders.count <= maximumFolders, organization.bookmarks.count <= maximumBookmarks else { throw LocalCollectionError.capacityReached }
        let folderIDs = Set(organization.folders.map(\.id))
        guard folderIDs.count == organization.folders.count,
              Set(organization.bookmarks.map(\.id)).count == organization.bookmarks.count else { throw LocalCollectionError.invalidArchive }
        var names = Set<String>()
        for folder in organization.folders {
            guard try folderName(folder.name) == folder.name, names.insert(folder.name.lowercased()).inserted else { throw LocalCollectionError.invalidArchive }
        }
        for bookmark in organization.bookmarks {
            let reference = bookmark.reference
            guard !reference.serviceID.isEmpty, reference.serviceID.utf8.count <= 256,
                  reference.serviceID.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
                  !reference.title.isEmpty, reference.title.utf8.count <= 4_096,
                  !reference.title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  bookmark.folderID.map(folderIDs.contains) ?? true,
                  bookmark.isPinned || bookmark.folderID != nil else { throw LocalCollectionError.invalidCollection }
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
}
