import Foundation
import MusicCore

public struct MusicCollection: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case playlist, album, artist, podcast }
    public let id: String
    public let kind: Kind
    public let title: String
    public let subtitle: String?
    public let artworkURL: URL?
    /// The radio or mix the service offered for this collection, if any.
    public let radioPlaylistID: String?
    public var isUploaded: Bool { MusicUploadRoutes.isCollectionID(id) }

    public init(id: String, kind: Kind, title: String, subtitle: String? = nil, artworkURL: URL? = nil,
                radioPlaylistID: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.radioPlaylistID = radioPlaylistID
    }
}

public enum MusicItem: Hashable, Identifiable, Sendable {
    case track(Track)
    case collection(MusicCollection)
    case browse(MusicBrowseReference)

    /// Content identity; use a separate occurrence identifier when building a playback queue.
    public var id: String {
        switch self {
        case let .track(track): track.episode.map { "episode:\($0.identity.key)" } ?? "track:\(track.id)"
        case let .collection(collection): "\(collection.kind.rawValue):\(collection.id)"
        case let .browse(reference): "browse:\(reference.browseID)|\(reference.params ?? "")"
        }
    }

    public var title: String {
        switch self {
        case let .track(track): track.title
        case let .collection(collection): collection.title
        case let .browse(reference): reference.title
        }
    }

    public var subtitle: String? {
        switch self {
        case let .track(track): track.artist
        case let .collection(collection): collection.subtitle
        case .browse: nil
        }
    }

    public var artworkURL: URL? {
        switch self {
        case let .track(track): track.artworkURL
        case let .collection(collection): collection.artworkURL
        case .browse: nil
        }
    }
}

public struct MusicSection: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let items: [MusicItem]
    public let browseReference: MusicBrowseReference?

    public init(id: String, title: String, items: [MusicItem], browseReference: MusicBrowseReference? = nil) {
        self.id = id
        self.title = title
        self.items = items
        self.browseReference = browseReference
    }
}

public struct MusicPlaylistItem: Hashable, Sendable {
    public let track: Track
    public let setVideoID: String?

    public init(track: Track, setVideoID: String? = nil) {
        self.track = track
        self.setVideoID = setVideoID
    }

    public var removalReference: PlaylistItemReference? {
        guard let setVideoID, !setVideoID.isEmpty else { return nil }
        return PlaylistItemReference(videoID: track.id, setVideoID: setVideoID)
    }
}

/// Actions explicitly offered by the current playlist response. Missing controls grant no permission.
public struct MusicPlaylistCapabilities: Hashable, Sendable {
    public var canRename: Bool
    public var canDelete: Bool
    public var canAddItems: Bool
    public var canRemoveItems: Bool
    public var canEditDescription: Bool
    public var canEditPrivacy: Bool
    public var canReorder: Bool

    public init(canRename: Bool = false, canDelete: Bool = false,
                canAddItems: Bool = false, canRemoveItems: Bool = false,
                canEditDescription: Bool = false, canEditPrivacy: Bool = false, canReorder: Bool = false) {
        self.canRename = canRename
        self.canDelete = canDelete
        self.canAddItems = canAddItems
        self.canRemoveItems = canRemoveItems
        self.canEditDescription = canEditDescription
        self.canEditPrivacy = canEditPrivacy
        self.canReorder = canReorder
    }
}

/// The service's song rating. A missing value is unknown, not neutral.
public enum MusicRating: String, Codable, Hashable, Sendable {
    case liked = "LIKE"
    case neutral = "INDIFFERENT"
    case disliked = "DISLIKE"
}

public struct MusicPage: Sendable {
    public let title: String
    public let sections: [MusicSection]
    public let items: [MusicItem]
    public let continuation: MusicContinuation?
    public let playlistItems: [MusicPlaylistItem]
    public let playlistCapabilities: MusicPlaylistCapabilities
    /// A missing entry means the response did not establish the song's like state.
    public let likeStates: [String: Bool]
    /// Authoritative three-state ratings. A legacy false like value cannot establish neutral versus disliked.
    public let ratings: [String: MusicRating]
    /// Rows explicitly marked unavailable by the service, excluded from playable items.
    /// Counts only the pages fetched so far, not the complete collection.
    public let unavailableItemCount: Int
    public let hasUnsupportedContent: Bool
    public let playlistDetails: MusicPlaylistDetails?
    public let albumLibraryState: MusicAlbumLibraryState?
    public let artistSubscription: MusicArtistSubscription?
    public var tracks: [Track] { items.compactMap { if case let .track(track) = $0 { track } else { nil } } }

    public init(title: String, sections: [MusicSection], items: [MusicItem], continuation: MusicContinuation? = nil,
                playlistItems: [MusicPlaylistItem] = [],
                playlistCapabilities: MusicPlaylistCapabilities = MusicPlaylistCapabilities(),
                likeStates: [String: Bool] = [:], ratings: [String: MusicRating] = [:],
                unavailableItemCount: Int = 0, hasUnsupportedContent: Bool = false,
                playlistDetails: MusicPlaylistDetails? = nil, albumLibraryState: MusicAlbumLibraryState? = nil,
                artistSubscription: MusicArtistSubscription? = nil) {
        self.title = title
        self.sections = sections
        self.items = items
        self.continuation = continuation
        self.playlistItems = playlistItems
        self.playlistCapabilities = playlistCapabilities
        self.playlistDetails = playlistDetails
        self.albumLibraryState = albumLibraryState
        self.artistSubscription = artistSubscription
        self.ratings = likeStates.compactMapValues { $0 ? .liked : nil }.merging(ratings) { _, explicit in explicit }
        self.likeStates = likeStates.merging(self.ratings.mapValues { $0 == .liked }) { _, explicit in explicit }
        self.unavailableItemCount = max(0, unavailableItemCount)
        self.hasUnsupportedContent = hasUnsupportedContent
    }
}

/// Opaque, account-bound pagination state. Retain it after a failed request to retry the same page.
public struct MusicContinuation: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let token: String
    let endpoint: MusicEndpoint
    let scope: UUID
    let title: String
    let requiresAuthentication: Bool
    let preservesOccurrences: Bool
    let previousTokens: Set<String>
    let previousItems: Set<String>
    let contentOrigin: MusicContentOrigin?

    init(token: String, endpoint: MusicEndpoint, scope: UUID, title: String, requiresAuthentication: Bool,
         preservesOccurrences: Bool, previousTokens: Set<String>, previousItems: Set<String>, contentOrigin: MusicContentOrigin? = nil) {
        self.token = token; self.endpoint = endpoint; self.scope = scope; self.title = title
        self.requiresAuthentication = requiresAuthentication; self.preservesOccurrences = preservesOccurrences
        self.previousTokens = previousTokens; self.previousItems = previousItems; self.contentOrigin = contentOrigin
    }
    public var description: String { "MusicContinuation" }
    public var debugDescription: String { description }
}

enum MusicEndpoint: String, Sendable {
    case browse, search, next
    case searchSuggestions = "music/get_search_suggestions"
}

public enum MusicServiceError: Error, Equatable, Sendable, LocalizedError {
    case signInRequired
    case authenticationRejected
    case accessDenied
    case sessionChanged
    case configurationUnavailable
    case invalidInput
    case invalidResponse
    case unsupportedResponse
    case paginationLoop
    case pageLimitReached
    case rateLimited
    case serviceUnavailable
    case httpStatus(Int)
    case network(URLError.Code)

    public var errorDescription: String? {
        switch self {
        case .signInRequired: ServiceLocalization.text("Sign in to view your library.")
        case .authenticationRejected: ServiceLocalization.text("YouTube Music did not accept this session. Open the sign-in window to check your account.")
        case .accessDenied: ServiceLocalization.text("YouTube Music declined this request. Your session has been kept.")
        case .sessionChanged: ServiceLocalization.text("The account changed while this page was loading.")
        case .configurationUnavailable: ServiceLocalization.text("YouTube Music could not provide its web client configuration. Open YouTube Music and try again.")
        case .invalidInput: ServiceLocalization.text("Enter a valid search or music identifier.")
        case .invalidResponse: ServiceLocalization.text("YouTube Music returned an unreadable response.")
        case .unsupportedResponse: ServiceLocalization.text("This YouTube Music page uses a format this version cannot read.")
        case .paginationLoop: ServiceLocalization.text("YouTube Music repeated a page. Loading stopped to avoid a loop.")
        case .pageLimitReached: ServiceLocalization.text("The page limit was reached. Load the remaining pages separately.")
        case .rateLimited: ServiceLocalization.text("YouTube Music is limiting requests. Try again later.")
        case .serviceUnavailable: ServiceLocalization.text("YouTube Music is temporarily unavailable.")
        case let .httpStatus(code): ServiceLocalization.format("YouTube Music returned HTTP %lld.", code)
        case .network: ServiceLocalization.text("Could not connect to YouTube Music. Check your connection and try again.")
        }
    }
}
