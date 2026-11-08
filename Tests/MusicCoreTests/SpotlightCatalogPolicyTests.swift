import Foundation
import Testing
@testable import MusicCore

@Suite("Bounded catalog Spotlight policy")
struct SpotlightCatalogPolicyTests {
    private let policy = SpotlightCatalogPolicy(namespace: "test.music.app")
    private let account = String(repeating: "a", count: 64)
    private let other = String(repeating: "b", count: 64)
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func domainsAreConfinedToThisAppsLibraryNamespaceAndConfirmedHashes() throws {
        let domain = try #require(policy.domain(accountKey: account))
        #expect(policy.owns(domain) && policy.owns(policy.rootDomain))
        for foreign in ["other.app.library", "test.music.app", policy.rootDomain + ".*", domain + ".child", "test.music.app.library." + String(repeating: "A", count: 64)] {
            #expect(!policy.owns(foreign))
        }
        #expect(policy.domain(accountKey: "../account") == nil)
        #expect(SpotlightCatalogPolicy(namespace: "").domain(accountKey: account) == nil)
    }

    @Test func versionedIdentifiersRoundTripOnlyCanonicalCatalogIdentityForTheSameAccount() throws {
        let original = LocalCollectionReference(serviceID: "VLPLone", kind: .playlist, title: "Private playlist name")
        let record = try #require(policy.records(from: [original], accountKey: account, now: date).first)
        #expect(record.reference.serviceID == "PLone")
        #expect(record.identifier == record.domain + "|v1|playlist|PLone")
        #expect(!record.identifier.contains(original.title))
        #expect(policy.reference(for: record.identifier, accountKey: account)?.serviceID == "PLone")
        #expect(policy.reference(for: record.identifier, accountKey: other) == nil)
        #expect(policy.accountKey(in: record.identifier) == account)
        #expect(record.expiresAt.timeIntervalSince(date) == SpotlightCatalogPolicy.lifetime)
    }

    @Test func malformedForeignFutureAndURLLikeResultsAreRejectedBeforeNavigation() throws {
        let domain = try #require(policy.domain(accountKey: account))
        for identifier in [domain + "|v99|playlist|PLone", domain + "|v1|podcast|PLone", domain + "|v1|playlist|VLPLone",
            domain + "|v1|playlist|https://example.com", domain + "|v1|playlist|file:///private", domain + "|v1|playlist|PLone|extra",
            "other.app.library." + account + "|v1|playlist|PLone", domain + "|v1|playlist|PLone?token=secret",
            domain + "|v1|playlist|" + String(repeating: "x", count: 600)] {
            #expect(policy.reference(for: identifier, accountKey: account) == nil)
            #expect(policy.accountKey(in: identifier) == nil)
        }
    }

    @Test func uploadsUnknownRoutesSongsAndMismatchedKindsCannotEnterTheIndex() {
        let rejected = [
            LocalCollectionReference(serviceID: "FEmusic_library_privately_owned_tracks", kind: .playlist, title: "Uploads"),
            LocalCollectionReference(serviceID: "FEmusic_library_privately_owned_release", kind: .album, title: "Upload album"),
            LocalCollectionReference(serviceID: "FEmusic_library_privately_owned_artist", kind: .artist, title: "Upload artist"),
            LocalCollectionReference(serviceID: "MPTYt-upload", kind: .album, title: "Unknown private release"),
            LocalCollectionReference(serviceID: "MPREb_", kind: .album, title: "Missing catalog identity"),
            LocalCollectionReference(serviceID: "UCartist", kind: .album, title: "Wrong kind"),
            LocalCollectionReference(serviceID: "abcDEF12_-3", kind: .playlist, title: "Song"),
            LocalCollectionReference(serviceID: "RDmix", kind: .playlist, title: "Mix")]
        #expect(policy.records(from: rejected, accountKey: account, now: date).isEmpty)
        let supported = [LocalCollectionReference(serviceID: "MPREb_catalog", kind: .album, title: "Album"),
                         LocalCollectionReference(serviceID: "UCcatalog", kind: .artist, title: "Artist")]
        #expect(policy.records(from: supported, accountKey: account, now: date).map(\.reference) == supported)
    }

    @Test func limitsDeduplicationAndTitleBoundsPreserveLoadedCatalogOrder() {
        var references = [LocalCollectionReference(serviceID: "VLPLone", kind: .playlist, title: "First"),
                          LocalCollectionReference(serviceID: "PLone", kind: .playlist, title: "Equivalent"),
                          LocalCollectionReference(serviceID: "PLlong", kind: .playlist, title: String(repeating: "é", count: 500))]
        references += (0..<600).map { LocalCollectionReference(serviceID: "PL\($0)", kind: .playlist, title: "Playlist \($0)") }
        let records = policy.records(from: references, accountKey: account, now: date)
        #expect(records.count == 500 && Set(records.map(\.identifier)).count == 500)
        #expect(records[0].reference.title == "First" && records[1].reference.title.count == 200)
        #expect(records[2].reference.serviceID == "PL0" && records.last?.reference.serviceID == "PL497")
    }
}
