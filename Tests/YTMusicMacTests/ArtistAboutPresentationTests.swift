import Foundation
import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

@MainActor @Suite("Frozen artist About presentation")
struct ArtistAboutPresentationTests {
    @Test func onlyTheCurrentArtistWithAvailableMetadataCanOpen() throws {
        let state = ArtistAboutPresentationState(), scope = try artistAboutScope()
        #expect(state.presentation == nil && state.current(for: scope) == nil)
        #expect(!state.open(scope, isCurrent: { _ in false }) && state.presentation == nil)
        #expect(state.open(scope, isCurrent: { $0 == scope }))
        #expect(state.current(for: scope)?.scope == scope)
        for destination in [MusicDestination.home, .collection(.init(id: "PLfixture", kind: .playlist, title: "Playlist")),
                            .collection(.init(id: "MPREfixture", kind: .album, title: "Album")), .uploads(.artists)] {
            #expect(ArtistAboutScope(profile: scope.profile, account: scope.account, destination: destination, about: scope.about) == nil)
        }
        #expect(ArtistAboutScope(profile: scope.profile, account: scope.account, destination: scope.destination, about: nil) == nil)
    }
    @Test func serviceArtistShelfDestinationsAreSupportedWithoutAdoptingOtherBrowseKinds() throws {
        let original = try artistAboutScope()
        let artist = MusicDestination.browse(.init(browseID: "UCfixture", params: "artist-params", title: "Artist shelf", kind: .artist))
        #expect(ArtistAboutScope(profile: original.profile, account: original.account, destination: artist, about: original.about)?.destination == artist)
        for kind in [MusicBrowseReference.Kind.playlist, .discography, .category] {
            let other = MusicDestination.browse(.init(browseID: "fixture", title: "Other shelf", kind: kind))
            #expect(ArtistAboutScope(profile: original.profile, account: original.account, destination: other, about: original.about) == nil)
        }
        let uploadID = "FEmusic_library_privately_owned_artist_detail_fixture"
        for destination in [MusicDestination.browse(.init(browseID: uploadID, title: "Upload", kind: .artist)),
                            .collection(.init(id: uploadID, kind: .artist, title: "Upload"))] {
            #expect(ArtistAboutScope(profile: original.profile, account: original.account, destination: destination, about: original.about) == nil)
        }
    }
    @Test func profileAccountDestinationOrDescriptionChangesCannotRefreshAnOldAuthority() throws {
        for field in 0..<4 {
            let state = ArtistAboutPresentationState(), original = try artistAboutScope(), changed = try artistAboutScope(replacing: original, field: field)
            #expect(state.open(original, isCurrent: { $0 == original }))
            let frozen = try #require(state.presentation)
            #expect(state.current(for: changed) == nil && state.presentation?.id == frozen.id)
            #expect(!state.open(original, isCurrent: { $0 == changed }))
            state.discardIfStale(current: changed)
            #expect(state.presentation == nil && state.current(for: original) == nil)
        }
    }
    @Test func anUnavailableOrSuspendedScopeHidesThenDiscardsThePresentation() throws {
        let state = ArtistAboutPresentationState(), scope = try artistAboutScope()
        #expect(state.open(scope, isCurrent: { _ in true }))
        #expect(state.current(for: nil) == nil)
        state.discardIfStale(current: nil)
        #expect(state.presentation == nil && state.current(for: scope) == nil)
    }
    @Test func lateDisappearanceCannotDismissANewExplicitPresentation() throws {
        let state = ArtistAboutPresentationState(), first = try artistAboutScope()
        #expect(state.open(first, isCurrent: { _ in true }))
        let oldID = try #require(state.presentation?.id)
        #expect(state.open(first, isCurrent: { _ in true }))
        let currentID = try #require(state.presentation?.id)
        #expect(currentID != oldID)
        state.dismiss(oldID)
        #expect(state.current(for: first)?.id == currentID)
        state.dismiss(currentID); #expect(state.presentation == nil)
    }
    @Test func aboutIsPlainCompleteSuppliedTextWithNoInventedAttribution() throws {
        let scope = try artistAboutScope(), state = ArtistAboutPresentationState()
        #expect(state.open(scope, isCurrent: { _ in true }))
        #expect(state.presentation?.scope.about.text == "Artist text %@ العربية\u{200f}\nComplete supplied credit")
        #expect(state.presentation?.scope.about.sourceURLs == ["https://source.example/exact?revision=2"])
    }
    @Test func englishAndFrenchContainEveryNativeAboutControl() throws {
        let keys = ["About This Artist…", "About This Artist", "Supplied Source Addresses", "Open this artist again to view current information."]
        for language in ["en", "fr"] {
            let folder = try #require(AppLocalization.bundle.url(forResource: language, withExtension: "lproj"))
            let bundle = try #require(Bundle(url: folder)), table = try #require(bundle.url(forResource: "Localizable", withExtension: "strings"))
            let values = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: table), format: nil) as? [String: String])
            for key in keys { #expect(values[key]?.isEmpty == false) }
            if language == "fr" { #expect(values["About This Artist"] == "À propos de cet artiste") }
        }
    }
}

private func artistAboutScope(replacing original: ArtistAboutScope? = nil, field: Int? = nil) throws -> ArtistAboutScope {
    let about = try #require(MusicArtistAbout(text: "Artist text %@ العربية\u{200f}\nComplete supplied credit", sourceURLs: ["https://source.example/exact?revision=2"]))
    let value = ArtistAboutScope(profile: field == 0 ? UUID() : original?.profile ?? UUID(),
        account: field == 1 ? UUID() : original?.account ?? UUID(),
        destination: field == 2 ? .collection(.init(id: "UCother", kind: .artist, title: "Other")) : original?.destination ?? .collection(.init(id: "UCfixture", kind: .artist, title: "Artist")),
        about: field == 3 ? MusicArtistAbout(text: "Changed supplied text") : about)
    return try #require(value)
}
