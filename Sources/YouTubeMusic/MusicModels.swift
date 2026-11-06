import Foundation
import MusicCore

public struct MusicCollection: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case playlist, album, artist }
    public let id: String
    public let kind: Kind
    public let title: String
    public let subtitle: String?
    public let artworkURL: URL?

    public init(id: String, kind: Kind, title: String, subtitle: String? = nil, artworkURL: URL? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
    }
}

public enum MusicItem: Hashable, Identifiable, Sendable {
    case track(Track)
    case collection(MusicCollection)

    /// Content identity; use a separate occurrence identifier when building a playback queue.
    public var id: String {
        switch self {
        case let .track(track): "track:\(track.id)"
        case let .collection(collection): "\(collection.kind.rawValue):\(collection.id)"
        }
    }

    public var title: String {
        switch self {
        case let .track(track): track.title
        case let .collection(collection): collection.title
        }
    }

    public var subtitle: String? {
        switch self {
        case let .track(track): track.artist
        case let .collection(collection): collection.subtitle
        }
    }

    public var artworkURL: URL? {
        switch self {
        case let .track(track): track.artworkURL
        case let .collection(collection): collection.artworkURL
        }
    }
}

public struct MusicSection: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let items: [MusicItem]

    public init(id: String, title: String, items: [MusicItem]) {
        self.id = id
        self.title = title
        self.items = items
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

public struct MusicPage: Sendable {
    public let title: String
    public let sections: [MusicSection]
    public let items: [MusicItem]
    public let continuation: MusicContinuation?
    public let playlistItems: [MusicPlaylistItem]
    public var tracks: [Track] { items.compactMap { if case let .track(track) = $0 { track } else { nil } } }

    public init(title: String, sections: [MusicSection], items: [MusicItem], continuation: MusicContinuation? = nil,
                playlistItems: [MusicPlaylistItem] = []) {
        self.title = title
        self.sections = sections
        self.items = items
        self.continuation = continuation
        self.playlistItems = playlistItems
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
    public var description: String { "MusicContinuation" }
    public var debugDescription: String { description }
}

enum MusicEndpoint: String, Sendable { case browse, search }

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
        case .signInRequired: "Sign in to view your library."
        case .authenticationRejected: "YouTube Music did not accept this session. Open the sign-in window to check your account."
        case .accessDenied: "YouTube Music declined this request. Your session has been kept."
        case .sessionChanged: "The account changed while this page was loading."
        case .configurationUnavailable: "YouTube Music could not provide its web client configuration. Open YouTube Music and try again."
        case .invalidInput: "Enter a valid search or music identifier."
        case .invalidResponse: "YouTube Music returned an unreadable response."
        case .unsupportedResponse: "This YouTube Music page uses a format this version cannot read."
        case .paginationLoop: "YouTube Music repeated a page. Loading stopped to avoid a loop."
        case .pageLimitReached: "The page limit was reached. Load the remaining pages separately."
        case .rateLimited: "YouTube Music is limiting requests. Try again later."
        case .serviceUnavailable: "YouTube Music is temporarily unavailable."
        case let .httpStatus(code): "YouTube Music returned HTTP \(code)."
        case .network: "Could not connect to YouTube Music. Check your connection and try again."
        }
    }
}
