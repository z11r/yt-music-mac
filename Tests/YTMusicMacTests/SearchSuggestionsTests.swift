import Foundation
import Testing
import YouTubeMusic
@testable import YTMusicMac

@Suite("Search suggestions") @MainActor
struct SearchSuggestionsTests {
    @Test func aResponseForOlderTextNeverReplacesNewerSuggestions() async {
        let gate = SuggestionGate()
        let suggestions = SearchSuggestions(delay: .zero) { try await gate.fetch($0) }
        suggestions.textChanged("old")
        let older = suggestions.task
        await gate.waitForRequest("old")
        suggestions.textChanged("new")
        let newer = suggestions.task
        await gate.waitForRequest("new")
        await gate.respond("new", with: ["new result"])
        await newer?.value
        #expect(suggestions.items.map(\.query) == ["new result"])
        // The older request was cancelled, but its response still arrives.
        await gate.respond("old", with: ["old result"])
        await older?.value
        #expect(suggestions.items.map(\.query) == ["new result"])
    }

    @Test func typingQuicklyRequestsOnlyTheLatestText() async {
        let gate = SuggestionGate()
        let suggestions = SearchSuggestions(delay: .milliseconds(30)) { try await gate.fetch($0) }
        suggestions.textChanged("a")
        suggestions.textChanged("ab")
        suggestions.textChanged("abc")
        let task = suggestions.task
        await gate.waitForRequest("abc")
        await gate.respond("abc", with: ["abc one", "abc two"])
        await task?.value
        #expect(await gate.requests == ["abc"])
        #expect(suggestions.items.map(\.query) == ["abc one", "abc two"])
    }

    @Test func closingDropsAPendingResponse() async {
        let gate = SuggestionGate()
        let suggestions = SearchSuggestions(delay: .zero) { try await gate.fetch($0) }
        suggestions.textChanged("pending")
        let task = suggestions.task
        await gate.waitForRequest("pending")
        suggestions.close()
        await gate.respond("pending", with: ["late"])
        await task?.value
        #expect(suggestions.items.isEmpty)
        #expect(!suggestions.isVisible)
    }

    @Test func aFailedRequestClosesTheList() async {
        let gate = SuggestionGate()
        let suggestions = SearchSuggestions(delay: .zero) { try await gate.fetch($0) }
        await show(["first"], for: "f", in: suggestions, gate: gate)
        suggestions.textChanged("fi")
        let task = suggestions.task
        await gate.waitForRequest("fi")
        await gate.fail("fi")
        await task?.value
        #expect(suggestions.items.isEmpty)
    }

    @Test func blankTextClosesTheListWithoutARequest() async {
        let gate = SuggestionGate()
        let suggestions = SearchSuggestions(delay: .zero) { try await gate.fetch($0) }
        await show(["first"], for: "f", in: suggestions, gate: gate)
        suggestions.textChanged("   ")
        #expect(suggestions.task == nil)
        #expect(suggestions.items.isEmpty)
        suggestions.textChanged("")
        #expect(await gate.requests == ["f"])
    }

    @Test func arrowKeysMoveTheHighlightAndUpFromTheTopReturnsToTheTypedText() async {
        let gate = SuggestionGate()
        let suggestions = SearchSuggestions(delay: .zero) { try await gate.fetch($0) }
        #expect(!suggestions.moveHighlight(by: 1), "A closed list leaves the key to the field.")
        await show(["one", "two", "three"], for: "t", in: suggestions, gate: gate)
        #expect(suggestions.highlightedIndex == nil)
        #expect(!suggestions.moveHighlight(by: -1), "Up with nothing highlighted moves the caret instead.")
        #expect(suggestions.moveHighlight(by: 1))
        #expect(suggestions.highlighted?.query == "one")
        suggestions.moveHighlight(by: 1)
        suggestions.moveHighlight(by: 1)
        suggestions.moveHighlight(by: 1)
        #expect(suggestions.highlighted?.query == "three", "Down stops at the last suggestion.")
        suggestions.moveHighlight(by: -1)
        suggestions.moveHighlight(by: -1)
        #expect(suggestions.highlighted?.query == "one")
        #expect(suggestions.moveHighlight(by: -1))
        #expect(suggestions.highlighted == nil)
        suggestions.close()
        #expect(!suggestions.moveHighlight(by: 1))
    }

    @Test func newTextClearsTheHighlightSoReturnSearchesWhatWasTyped() async {
        let gate = SuggestionGate()
        let suggestions = SearchSuggestions(delay: .zero) { try await gate.fetch($0) }
        await show(["one", "two"], for: "o", in: suggestions, gate: gate)
        suggestions.moveHighlight(by: 1)
        suggestions.textChanged("on")
        #expect(suggestions.highlighted == nil)
        #expect(suggestions.items.map(\.query) == ["one", "two"], "The list stays until new suggestions arrive.")
    }

    @Test func filledInTextDoesNotReopenTheListButTheNextEditDoes() async {
        let gate = SuggestionGate()
        let suggestions = SearchSuggestions(delay: .zero) { try await gate.fetch($0) }
        suggestions.close(ignoringNextChangeTo: "chosen")
        suggestions.textChanged("chosen")
        #expect(suggestions.task == nil)
        await show(["chosen two"], for: "chosen ", in: suggestions, gate: gate)
        #expect(await gate.requests == ["chosen "])
    }

    @Test func theListShowsAtMostEightSuggestions() async {
        let gate = SuggestionGate()
        let suggestions = SearchSuggestions(delay: .zero) { try await gate.fetch($0) }
        await show((1...12).map { "result \($0)" }, for: "r", in: suggestions, gate: gate)
        #expect(suggestions.items.count == SearchSuggestions.maximumCount)
        #expect(suggestions.items.first?.query == "result 1")
    }

    private func show(_ queries: [String], for text: String, in suggestions: SearchSuggestions,
                      gate: SuggestionGate) async {
        suggestions.textChanged(text)
        let task = suggestions.task
        await gate.waitForRequest(text)
        await gate.respond(text, with: queries)
        await task?.value
    }
}

/// Holds each suggestion request until the test answers it.
actor SuggestionGate {
    private var waiting: [String: CheckedContinuation<[MusicSearchSuggestion], any Error>] = [:]
    private var arrivals: [String: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var requests: [String] = []

    func fetch(_ text: String) async throws -> [MusicSearchSuggestion] {
        requests.append(text)
        arrivals.removeValue(forKey: text)?.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { waiting[text] = $0 }
    }

    func waitForRequest(_ text: String) async {
        if requests.contains(text) { return }
        await withCheckedContinuation { arrivals[text, default: []].append($0) }
    }

    func respond(_ text: String, with queries: [String]) {
        waiting.removeValue(forKey: text)?.resume(returning: queries.map { MusicSearchSuggestion(query: $0) })
    }

    func fail(_ text: String) {
        waiting.removeValue(forKey: text)?.resume(throwing: URLError(.timedOut))
    }
}
