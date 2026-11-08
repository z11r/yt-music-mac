import Foundation
import Testing
@testable import YTMusicMac

@Suite("Local recent searches") @MainActor
struct SearchHistoryTests {
    @Test func theNewestQueryMovesToTheFrontWithoutDuplicates() {
        let history = SearchHistory()
        history.record("  Björk  ")
        history.record("live piano")
        history.record("björk")
        #expect(history.queries == ["björk", "live piano"])
    }

    @Test func invalidQueriesAreNotRemembered() {
        let history = SearchHistory()
        for query in ["", "  \n ", "piano\nrock", "piano\trock", String(repeating: "a", count: 501)] {
            history.record(query)
        }
        #expect(history.queries.isEmpty)
    }

    @Test func oldQueriesAreBoundedAndCanBeCleared() {
        let history = SearchHistory()
        for index in 0...SearchHistory.maximumCount { history.record("query \(index)") }
        #expect(history.queries.count == SearchHistory.maximumCount)
        #expect(history.queries.first == "query \(SearchHistory.maximumCount)")
        #expect(!history.queries.contains("query 0"))
        history.clear()
        #expect(history.queries.isEmpty)
    }

    @Test func anotherAppSessionNeverReadsAnEarlierSessionsQueries() {
        let old = SearchHistory()
        old.record("private query")
        #expect(SearchHistory().queries.isEmpty)
    }
}
