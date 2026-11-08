import Foundation

/// A catalog identity supplied with track metadata, independent of any service UI.
public struct TrackMetadataReference: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}
