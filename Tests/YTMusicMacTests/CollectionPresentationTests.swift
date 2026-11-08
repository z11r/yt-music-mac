import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

@Suite("Loaded collection display")
struct CollectionPresentationTests {
    @Test func displaySortingKeepsDuplicateOccurrencesAndTheirRemovalReferences() {
        let tracks = [track("same", "Mix 10"), track("other", "Mix 2"), track("same", "Mix 10")]
        let page = page(tracks)
        let rows = CollectionPresentation.rows(in: page, matching: "", order: .titleAscending)
        #expect(rows.map(\.id) == [1, 0, 2])
        #expect(rows.map { $0.removalReference?.setVideoID } == ["occurrence-1", "occurrence-0", "occurrence-2"])
        #expect(page.tracks == tracks)
        #expect(CollectionPresentation.rows(in: page, matching: "", order: .serviceOrder).map(\.id) == [0, 1, 2])
    }

    @Test func filteringIncludesAlbumAndPreservesTheOriginalOrdinal() {
        let a = track("a", "First", artist: "Singer", album: "Record")
        let b = track("b", "Second", artist: "Other", album: "Different")
        let page = page([a, b, a])
        let rows = CollectionPresentation.rows(in: page, matching: "  record  ", order: .titleDescending)
        #expect(rows.map(\.id) == [0, 2])
        #expect(rows.map { $0.removalReference?.setVideoID } == ["occurrence-0", "occurrence-2"])
        #expect(CollectionPresentation.rows(in: page, matching: "singer", order: .serviceOrder).count == 2)
        #expect(CollectionPresentation.rows(in: page, matching: "missing", order: .serviceOrder).isEmpty)
    }

    @Test func unknownDurationsStayLastInBothDirectionsAndTiesKeepServiceOrder() {
        let page = page([track("a", "A", duration: nil), track("b", "B", duration: 20),
                         track("c", "C", duration: 10), track("d", "D", duration: 20)])
        #expect(CollectionPresentation.rows(in: page, matching: "", order: .durationAscending).map(\.id) == [2, 1, 3, 0])
        #expect(CollectionPresentation.rows(in: page, matching: "", order: .durationDescending).map(\.id) == [1, 3, 2, 0])
    }

    @Test func artistAndAlbumSortingKeepUnknownMetadataUnknown() {
        let page = page([track("a", "A", artist: "Z", album: nil),
                         track("b", "B", artist: "A", album: "Record 10"),
                         track("c", "C", artist: "A", album: "Record 2")])
        #expect(CollectionPresentation.rows(in: page, matching: "", order: .artistAscending).map(\.id) == [1, 2, 0])
        #expect(CollectionPresentation.rows(in: page, matching: "", order: .albumAscending).map(\.id) == [2, 1, 0])
    }

    @Test func mismatchedOccurrenceMetadataCannotBeBorrowedAfterSorting() {
        let a = track("same", "A"), b = track("same", "B")
        let page = MusicPage(title: "Playlist", sections: [], items: [.track(a), .track(b)],
            playlistItems: [.init(track: b, setVideoID: "other"), .init(track: a, setVideoID: "wrong")])
        #expect(CollectionPresentation.rows(in: page, matching: "", order: .titleDescending)
            .allSatisfy { $0.removalReference == nil })
    }

    @Test func sectionFallbackAndLoadedLibrarySearchRetainMatchingItemsOnly() {
        let a = track("a", "First", artist: "Performer"), b = track("b", "Other")
        let page = MusicPage(title: "Playlist", sections: [.init(id: "s", title: "", items: [.track(a), .track(b)])], items: [])
        #expect(CollectionPresentation.rows(in: page, matching: "Performer", order: .serviceOrder).map(\.id) == [0])
        let items: [MusicItem] = [.track(a), .track(b), .track(a)]
        #expect(LibraryDisplayOrder.filtered(items, matching: "Performer").map(\.id) == ["track:a", "track:a"])
        #expect(LibraryDisplayOrder.filtered(items, matching: "  ") == items)
    }

    private func track(_ id: String, _ title: String, artist: String = "Artist", album: String? = nil,
                       duration: Double? = nil) -> Track {
        Track(id: id, title: title, artist: artist, album: album, duration: duration)
    }
    private func page(_ tracks: [Track]) -> MusicPage {
        MusicPage(title: "Playlist", sections: [], items: tracks.map(MusicItem.track),
            playlistItems: tracks.enumerated().map { .init(track: $0.element, setVideoID: "occurrence-\($0.offset)") })
    }
}
