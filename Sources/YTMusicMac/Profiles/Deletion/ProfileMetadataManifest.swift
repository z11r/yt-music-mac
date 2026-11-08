import Foundation

struct ProfileMetadataIdentity: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let generation: UInt32
    let owner: UInt32
    let mode: UInt16
    let links: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    func sameDirectory(as other: Self) -> Bool {
        device == other.device && inode == other.inode && generation == other.generation && owner == other.owner && mode == other.mode
    }
}
struct ProfileMetadataFile: Codable, Equatable, Sendable {
    let path: String
    let identity: ProfileMetadataIdentity
    let digest: Data
    let schema: ProfileMetadataSchemaProof
    var state: ProfileCleanupState = .pending
}
struct ProfileMetadataFolder: Codable, Equatable, Sendable {
    let path: String
    let identity: ProfileMetadataIdentity
}
struct ProfileMetadataManifest: Codable, Equatable, Sendable {
    static let maximumFiles = 64
    static let maximumFolders = 128
    static let maximumBytes: Int64 = 128 << 20
    var files: [ProfileMetadataFile]
    var folders: [ProfileMetadataFolder]
    func validate() throws {
        guard files.count <= Self.maximumFiles, folders.count <= Self.maximumFolders,
              Set(files.map(\.path)).count == files.count, Set(folders.map(\.path)).count == folders.count,
              folders.contains(where: { $0.path.isEmpty }),
              files.allSatisfy({ (0...Self.maximumBytes).contains($0.identity.size) }) else { throw AppProfileError.invalidRegistry }
        var total: Int64 = 0
        for file in files {
            total += file.identity.size
            guard total <= Self.maximumBytes else { throw AppProfileError.invalidRegistry }
            guard let format = ProfileMetadataFormat.identify(file.path), file.digest.count == 32,
                  file.identity.size >= 0, file.identity.size <= format.byteLimit,
                  file.identity.links == 1, file.identity.mode == 0o100600,
                  format == .storeLock ? file.schema == .init(version: 0, revision: nil) : file.schema.version > 0 else { throw AppProfileError.invalidRegistry }
        }
        for folder in folders {
            guard ProfileMetadataPaths.isFolder(folder.path), folder.identity.mode & 0o170000 == 0o040000 else { throw AppProfileError.invalidRegistry }
        }
    }
    /// Compare complete inventories. Absence is recoverable; new/replaced data is not.
    func accepts(_ current: Self) -> Bool {
        let knownFiles = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        let knownFolders = Dictionary(uniqueKeysWithValues: folders.map { ($0.path, $0) })
        return current.files.allSatisfy { item in
            guard let old = knownFiles[item.path], old.state != .complete else { return false }
            return old.identity == item.identity && old.digest == item.digest && old.schema == item.schema
        } && current.folders.allSatisfy { item in
            knownFolders[item.path].map { $0.identity.sameDirectory(as: item.identity) } == true
        }
    }
}
enum ProfileMetadataPaths {
    static let accountFolders: Set<String> = ["SavedQueues", "LocalCollections", "MetadataCache", "LocalSongRules", "PendingQueuePlaylists"]
    static let flatFolders: Set<String> = ["episode-progress", "listenbrainz", "lastfm", "LocalAudio"]
    static func isFolder(_ path: String) -> Bool {
        if path.isEmpty { return true }
        let p = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if p.count == 1 { return accountFolders.contains(p[0]) || flatFolders.contains(p[0]) }
        return p.count == 2 && accountFolders.contains(p[0]) && EpisodeProgressAccountKey.accepts(p[1])
    }
}

/// The controller persists each running marker before the adapter may unlink.
@MainActor protocol ProfileMetadataCleaning: ProfileCleanupSession {
    func reviewMetadata(recovering: ProfileMetadataManifest?) async throws -> ProfileMetadataManifest?
    func validateMetadata(_ manifest: ProfileMetadataManifest) async throws
    func metadataFileIsPresent(_ file: ProfileMetadataFile, manifest: ProfileMetadataManifest) async throws -> Bool
    func removeMetadataFile(_ file: ProfileMetadataFile, manifest: ProfileMetadataManifest) async throws
    func finishMetadata(_ manifest: ProfileMetadataManifest) async throws
}

extension ProfileMetadataIdentity {
    private enum Keys: String, CodingKey { case device, inode, generation, owner, mode, links, size, modifiedSeconds, modifiedNanoseconds, changedSeconds, changedNanoseconds }
    init(from decoder: any Decoder) throws {
        try ProfileSchema.keys(decoder, ["device", "inode", "generation", "owner", "mode", "links", "size", "modifiedSeconds", "modifiedNanoseconds", "changedSeconds", "changedNanoseconds"])
        let c = try decoder.container(keyedBy: Keys.self)
        device = try c.decode(Int32.self, forKey: .device)
        inode = try c.decode(UInt64.self, forKey: .inode)
        generation = try c.decode(UInt32.self, forKey: .generation)
        owner = try c.decode(UInt32.self, forKey: .owner)
        mode = try c.decode(UInt16.self, forKey: .mode)
        links = try c.decode(UInt64.self, forKey: .links)
        size = try c.decode(Int64.self, forKey: .size)
        modifiedSeconds = try c.decode(Int64.self, forKey: .modifiedSeconds)
        modifiedNanoseconds = try c.decode(Int64.self, forKey: .modifiedNanoseconds)
        changedSeconds = try c.decode(Int64.self, forKey: .changedSeconds)
        changedNanoseconds = try c.decode(Int64.self, forKey: .changedNanoseconds)
    }
}

extension ProfileMetadataSchemaProof {
    private enum Keys: String, CodingKey { case version, revision }
    init(from decoder: any Decoder) throws {
        try ProfileSchema.keys(decoder, ["version", "revision"])
        let c = try decoder.container(keyedBy: Keys.self)
        version = try c.decode(Int.self, forKey: .version)
        revision = try c.decodeIfPresent(UUID.self, forKey: .revision)
    }
}

extension ProfileMetadataFile {
    private enum Keys: String, CodingKey { case path, identity, digest, schema, state }
    init(from decoder: any Decoder) throws {
        try ProfileSchema.keys(decoder, ["path", "identity", "digest", "schema", "state"])
        let c = try decoder.container(keyedBy: Keys.self)
        path = try c.decode(String.self, forKey: .path)
        identity = try c.decode(ProfileMetadataIdentity.self, forKey: .identity)
        digest = try c.decode(Data.self, forKey: .digest)
        schema = try c.decode(ProfileMetadataSchemaProof.self, forKey: .schema)
        state = try c.decode(ProfileCleanupState.self, forKey: .state)
    }
}

extension ProfileMetadataFolder {
    private enum Keys: String, CodingKey { case path, identity }
    init(from decoder: any Decoder) throws {
        try ProfileSchema.keys(decoder, ["path", "identity"])
        let c = try decoder.container(keyedBy: Keys.self)
        path = try c.decode(String.self, forKey: .path)
        identity = try c.decode(ProfileMetadataIdentity.self, forKey: .identity)
    }
}

extension ProfileMetadataManifest {
    private enum Keys: String, CodingKey { case files, folders }
    init(from decoder: any Decoder) throws {
        try ProfileSchema.keys(decoder, ["files", "folders"])
        let c = try decoder.container(keyedBy: Keys.self)
        files = try c.decode([ProfileMetadataFile].self, forKey: .files)
        folders = try c.decode([ProfileMetadataFolder].self, forKey: .folders)
    }
}
