import Foundation

/// An opaque credits destination supplied by the exact song's own service menu.
/// A playback video identifier alone never establishes this reference.
public struct SongCreditsReference: Codable, Hashable, Sendable {
    public let browseID: String

    public init?(browseID: String) {
        guard browseID.hasPrefix("MPTC"), (5...256).contains(browseID.utf8.count),
              browseID.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
              }) else { return nil }
        self.browseID = browseID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(String.self, forKey: .browseID)
        guard let reference = Self(browseID: value) else {
            throw DecodingError.dataCorruptedError(forKey: .browseID, in: container, debugDescription: "Invalid song credits reference")
        }
        self = reference
    }
}
