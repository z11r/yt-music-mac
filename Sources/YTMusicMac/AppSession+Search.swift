import Foundation
import Observation
import YouTubeMusic

extension AppSession {
    /// Searches for the highlighted suggestion, or for the typed text when none is highlighted.
    func submitSearch() {
        guard acceptsProfileActions else { return }
        if searchScope == .library { searchSuggestions.close(); searchYourLibrary(); return }
        if let suggestion = searchSuggestions.highlighted {
            search(for: suggestion)
            return
        }
        searchSuggestions.close(ignoringNextChangeTo: searchText)
        search()
    }

    func search(for suggestion: MusicSearchSuggestion) {
        guard acceptsProfileActions else { return }
        // Filling in the field must not reopen the list it was chosen from.
        searchSuggestions.close(ignoringNextChangeTo: suggestion.query)
        searchText = suggestion.query
        search()
    }

    func searchTextChanged() {
        guard acceptsProfileActions else { return }
        guard searchScope == .catalog else { searchSuggestions.close(); return }
        searchSuggestions.textChanged(searchText)
    }

    /// Runs the current search again with the new filter. `navigate` cancels the
    /// older request and ignores its response, so it cannot replace the new results.
    func searchFilterChanged() {
        guard !syncingSearchDestination, case let .search(query, _) = destination else { return }
        navigate(to: .search(query, filter: searchFilter))
    }

    func librarySearchFilterChanged() {
        guard !syncingSearchDestination, case let .librarySearch(query, _) = destination else { return }
        navigate(to: .librarySearch(query, librarySearchFilter))
    }

    func searchYourLibrary() {
        guard acceptsProfileActions else { return }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchHistory.record(query, source: .library(librarySearchFilter))
        navigate(to: .librarySearch(query, librarySearchFilter))
    }

    func repeatSearch(_ entry: RecentSearch) {
        guard acceptsProfileActions else { return }
        searchSuggestions.close(ignoringNextChangeTo: entry.query)
        searchText = entry.query
        switch entry.source {
        case let .catalog(filter): navigate(to: .search(entry.query, filter: filter))
        case let .library(filter): navigate(to: .librarySearch(entry.query, filter))
        }
        searchHistory.record(entry.query, source: entry.source)
    }
}

/// Suggestions for the search field while someone types. At most one request is
/// pending, and a response is shown only if no newer text or action came after it.
@MainActor @Observable
final class SearchSuggestions {
    static let maximumCount = 8

    /// The suggestions on screen; empty while the list is closed.
    private(set) var items: [MusicSearchSuggestion] = []
    /// `nil` means the typed text is current, so Return searches for it.
    private(set) var highlightedIndex: Int?

    @ObservationIgnored private let fetch: @Sendable (String) async throws -> [MusicSearchSuggestion]
    @ObservationIgnored private let delay: Duration
    /// The pending request, if any. Tests await it instead of sleeping.
    @ObservationIgnored private(set) var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ignoredText: String?

    init(delay: Duration = .milliseconds(200),
         fetch: @escaping @Sendable (String) async throws -> [MusicSearchSuggestion]) {
        self.delay = delay
        self.fetch = fetch
    }

    var isVisible: Bool { !items.isEmpty }

    var highlighted: MusicSearchSuggestion? {
        guard let highlightedIndex, items.indices.contains(highlightedIndex) else { return nil }
        return items[highlightedIndex]
    }

    /// Waits for a pause in typing, then asks for suggestions for `text`.
    func textChanged(_ text: String) {
        if let ignored = ignoredText {
            ignoredText = nil
            if ignored == text { return }
        }
        cancelPending()
        highlightedIndex = nil
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 500,
              !text.contains(where: \.isNewline) else {
            items = []
            return
        }
        let request = generation
        task = Task { [weak self, fetch, delay] in
            do {
                try await Task.sleep(for: delay)
                let result = try await fetch(text)
                guard let self, !Task.isCancelled, self.generation == request else { return }
                self.items = Array(result.prefix(Self.maximumCount))
                self.highlightedIndex = nil
            } catch {
                // Suggestions are optional. A failure closes the list; the next keystroke tries again.
                guard let self, !Task.isCancelled, self.generation == request else { return }
                self.items = []
                self.highlightedIndex = nil
            }
        }
    }

    /// Moves the highlight down (positive) or up (negative). Moving up from the first
    /// suggestion returns to the typed text. Returns `false` when there is nothing to
    /// move, so the key can do its usual job in the field.
    @discardableResult
    func moveHighlight(by offset: Int) -> Bool {
        guard isVisible, offset != 0 else { return false }
        if offset > 0 {
            highlightedIndex = min((highlightedIndex ?? -1) + offset, items.count - 1)
        } else {
            guard let current = highlightedIndex else { return false }
            let target = current + offset
            highlightedIndex = target >= 0 ? target : nil
        }
        return true
    }

    func highlight(_ index: Int?) {
        guard let index else { highlightedIndex = nil; return }
        if items.indices.contains(index) { highlightedIndex = index }
    }

    /// Closes the list and drops any pending request.
    func close() {
        cancelPending()
        items = []
        highlightedIndex = nil
    }

    /// Closes the list. If the search text next changes to `text` (because the
    /// app filled it in), that change does not request suggestions.
    func close(ignoringNextChangeTo text: String) {
        close()
        ignoredText = text
    }

    private func cancelPending() {
        task?.cancel()
        task = nil
        generation &+= 1
    }
}
