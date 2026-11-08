// Request and response paths follow ytmusicapi's ChartsMixin. See THIRD_PARTY_NOTICES.md.
import Foundation

/// An offered country choice belongs to the session that returned it.
public struct MusicChartCountry: Hashable, Sendable {
    public let code: String
    let scope: UUID
    var isValid: Bool { code.utf8.count == 2 && code.utf8.allSatisfy { (65...90).contains($0) } }
}

public struct MusicChartsPage: Sendable {
    public let page: MusicPage
    public let countries: [MusicChartCountry]
    /// The service's own filter label; the request alone does not confirm selection.
    public let selectedCountryLabel: String?
}

extension YouTubeMusicClient {
    public func charts(country: MusicChartCountry? = nil) async throws -> MusicChartsPage {
        let session = await sessions.snapshot()
        if let country {
            guard country.isValid else { throw MusicServiceError.invalidInput }
            guard country.scope == session.scope else { throw MusicServiceError.sessionChanged }
        }
        var body: [String: Any] = ["browseId": "FEmusic_charts"]
        if let country { body["formData"] = ["selectedValues": [country.code]] }
        let data = try await request(endpoint: .browse, body: body, session: session, requiresAuthentication: false)
        let parsed = try MusicResponseParser.parse(data, preservesOccurrences: false)
        let root = try JSONDecoder().decode(JSONNode.self, from: data)
        var seen = Set<String>()
        let countries = root["frameworkUpdates"]["entityBatchUpdate"]["mutations"].array.prefix(512).compactMap { mutation -> MusicChartCountry? in
            guard let code = mutation["payload"]["musicFormBooleanChoice"]["opaqueToken"].string,
                  code.utf8.count == 2, code.utf8.allSatisfy({ (65...90).contains($0) }), seen.insert(code).inserted else { return nil }
            return MusicChartCountry(code: code, scope: session.scope)
        }
        let tabs = root["contents"]["singleColumnBrowseResultsRenderer"]["tabs"].array
        let firstSection = tabs.first?["tabRenderer"]["content"]["sectionListRenderer"]["contents"].array.first
        let header = firstSection?["musicShelfRenderer"]["subheaders"].array.first
        let start = header?["musicSideAlignedItemRenderer"]["startItems"].array.first
        let label = start?["musicSortFilterButtonRenderer"]["title"].text
        let validLabel = label.flatMap { value -> String? in
            value.utf8.count <= 1_024 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ? value : nil
        }
        return MusicChartsPage(page: makePage(parsed, title: ServiceLocalization.text("Charts"), endpoint: .browse,
            session: session, requiresAuthentication: false, preservesOccurrences: false),
            countries: Array(countries.prefix(300)), selectedCountryLabel: validLabel)
    }
}
