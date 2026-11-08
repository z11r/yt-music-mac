import Foundation
import MusicCore
import Testing
import YouTubeMusic
@testable import YTMusicMac

@Suite("Loaded library display order")
struct LibraryDisplayOrderTests {
    @Test func serviceOrderIsPreservedUntilAnExplicitDisplaySortIsChosen() {
        let items = [collection("last", title: "Zebra"), collection("first", title: "Album")]
        #expect(LibraryDisplayOrder.serviceOrder.sorted(items).map(\.id) == items.map(\.id))
        #expect(LibraryDisplayOrder.titleAscending.sorted(items).map(\.id) == ["album:first", "album:last"])
        #expect(items.map(\.id) == ["album:last", "album:first"])
    }

    @Test func titleSortUsesNaturalNumbersAndSupportsDescendingOrder() {
        let items = [collection("ten", title: "Mix 10"), collection("two", title: "Mix 2"), collection("one", title: "Mix 1")]
        #expect(LibraryDisplayOrder.titleAscending.sorted(items).map(\.id) == ["album:one", "album:two", "album:ten"])
        #expect(LibraryDisplayOrder.titleDescending.sorted(items).map(\.id) == ["album:ten", "album:two", "album:one"])
    }

    @Test func equalTitlesKeepServiceOrderWithoutDroppingDistinctItems() {
        let items = [collection("one", title: "Same"), collection("two", title: "Same"), collection("three", title: "Same")]
        for order in LibraryDisplayOrder.allCases {
            #expect(order.sorted(items).map(\.id) == items.map(\.id))
        }
    }

    @Test func repeatedItemsRemainDistinctAndAnEmptyLibraryCanBeSorted() {
        let repeated = MusicItem.track(Track(id: "same", title: "Same", artist: "Artist"))
        #expect(LibraryDisplayOrder.titleAscending.sorted([repeated, repeated]).count == 2)
        #expect(LibraryDisplayOrder.titleDescending.sorted([]).isEmpty)
    }

    private func collection(_ id: String, title: String) -> MusicItem {
        .collection(MusicCollection(id: id, kind: .album, title: title))
    }
}
