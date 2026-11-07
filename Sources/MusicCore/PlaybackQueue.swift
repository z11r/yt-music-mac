import Foundation

public struct PlaybackQueue: Sendable {
    public private(set) var entries: [QueueEntry] = []
    public private(set) var currentEntryID: UUID?
    public private(set) var currentOccurrence: PlaybackOccurrence?
    public var repeatMode: RepeatMode = .off
    public private(set) var isShuffled = false

    private let sessionID = UUID()
    private var generation: UInt64 = 0
    private var unshuffledOrder: [UUID] = []
    private let undoLimit: Int
    private var undoHistory: [EditState] = []

    private struct EditState: Sendable {
        let entries: [QueueEntry]
        let selectedID: UUID?
        let unshuffledOrder: [UUID]
        let isShuffled: Bool
    }

    public init(undoLimit: Int = 20) {
        self.undoLimit = max(0, undoLimit)
    }

    public init(snapshot: QueueSnapshot, undoLimit: Int = 20) throws {
        try snapshot.validate()
        self.undoLimit = max(0, undoLimit)
        self.entries = snapshot.entries
        self.currentEntryID = snapshot.currentEntryID
        self.repeatMode = snapshot.repeatMode
        self.isShuffled = snapshot.isShuffled
        self.unshuffledOrder = snapshot.unshuffledOrder
        // A restored selection is not a request to start playback.
        self.currentOccurrence = nil
    }

    public var currentIndex: Int? {
        guard let currentEntryID else { return nil }
        return self.entries.firstIndex { $0.id == currentEntryID }
    }

    public var currentEntry: QueueEntry? {
        self.currentIndex.map { self.entries[$0] }
    }

    public var currentTrack: Track? { self.currentEntry?.track }
    public var canUndo: Bool { !self.undoHistory.isEmpty }
    public var isEmpty: Bool { self.entries.isEmpty }

    public var hasNext: Bool {
        guard let index = self.currentIndex else { return !self.entries.isEmpty }
        return index + 1 < self.entries.count || self.repeatMode == .all
    }

    public var hasPrevious: Bool {
        guard let index = self.currentIndex else { return !self.entries.isEmpty }
        return index > 0 || self.repeatMode == .all
    }

    /// Passing a valid starting index requests playback. Omitting it only loads the queue.
    @discardableResult
    public mutating func replace(with tracks: [Track], startAt: Int? = nil) -> PlaybackOccurrence? {
        self.rememberEdit()
        self.entries = tracks.filter { !$0.id.isEmpty }.map { QueueEntry(track: $0) }
        self.unshuffledOrder = self.entries.map(\.id)
        self.currentEntryID = self.entries.first?.id
        self.currentOccurrence = nil

        var selected: QueueEntry?
        if let startAt, self.entries.indices.contains(startAt) {
            selected = self.entries[startAt]
            self.currentEntryID = selected?.id
        }
        if self.isShuffled {
            var generator = SystemRandomNumberGenerator()
            self.shuffleUpcoming(using: &generator)
        }
        return selected.map { self.requestPlayback(of: $0) }
    }

    @discardableResult
    public mutating func select(entryID: UUID) -> PlaybackOccurrence? {
        guard let entry = self.entries.first(where: { $0.id == entryID }) else { return nil }
        return self.requestPlayback(of: entry)
    }

    /// Starts or reissues the selected entry after an explicit play or retry action.
    @discardableResult
    public mutating func beginPlayback() -> PlaybackOccurrence? {
        guard let entry = self.currentEntry ?? self.entries.first else { return nil }
        return self.requestPlayback(of: entry)
    }

    /// Retains the queue after stopping or a playback failure.
    public mutating func invalidatePlayback() {
        self.currentOccurrence = nil
    }

    public func accepts(_ occurrence: PlaybackOccurrence) -> Bool {
        self.currentOccurrence == occurrence
    }

    @discardableResult
    public mutating func next() -> PlaybackOccurrence? {
        guard let index = self.currentIndex else { return self.beginPlayback() }
        if index + 1 < self.entries.count {
            return self.requestPlayback(of: self.entries[index + 1])
        }
        if self.repeatMode == .all, let entry = self.entries.first {
            return self.requestPlayback(of: entry)
        }
        return nil
    }

    @discardableResult
    public mutating func previous() -> PlaybackOccurrence? {
        guard let index = self.currentIndex else { return self.beginPlayback() }
        if index > 0 {
            return self.requestPlayback(of: self.entries[index - 1])
        }
        if self.repeatMode == .all, let entry = self.entries.last {
            return self.requestPlayback(of: entry)
        }
        return nil
    }

    /// Consumes only the ending for the currently requested occurrence.
    @discardableResult
    public mutating func handleEnd(occurrence: PlaybackOccurrence) -> PlaybackOccurrence? {
        guard self.accepts(occurrence), let entry = self.currentEntry else { return nil }
        self.currentOccurrence = nil
        if self.repeatMode == .one {
            return self.requestPlayback(of: entry)
        }
        return self.next()
    }

    @discardableResult
    public mutating func append(_ tracks: [Track]) -> [QueueEntry] {
        let additions = tracks.filter { !$0.id.isEmpty }.map { QueueEntry(track: $0) }
        guard !additions.isEmpty else { return [] }
        self.rememberEdit()
        self.entries.append(contentsOf: additions)
        self.unshuffledOrder.append(contentsOf: additions.map(\.id))
        return additions
    }

    @discardableResult
    public mutating func playNext(_ tracks: [Track]) -> [QueueEntry] {
        let additions = tracks.filter { !$0.id.isEmpty }.map { QueueEntry(track: $0) }
        guard !additions.isEmpty else { return [] }
        self.rememberEdit()
        let insertion = self.currentIndex.map { $0 + 1 } ?? 0
        self.entries.insert(contentsOf: additions, at: insertion)
        let originalInsertion = self.currentEntryID
            .flatMap { self.unshuffledOrder.firstIndex(of: $0) }
            .map { $0 + 1 } ?? 0
        self.unshuffledOrder.insert(contentsOf: additions.map(\.id), at: originalInsertion)
        return additions
    }

    /// Removing an entry with an active occurrence requests its successor.
    /// A restored or stopped selection stays inactive. Transport pause intent belongs to the player.
    public mutating func remove(entryIDs: Set<UUID>) {
        guard self.entries.contains(where: { entryIDs.contains($0.id) }) else { return }
        self.rememberEdit()
        let previousIndex = self.currentIndex ?? 0
        let successorIndex = self.entries.prefix(previousIndex).filter { !entryIDs.contains($0.id) }.count
        let wasActive = self.currentOccurrence != nil
        let removedSelection = self.currentEntryID.map { entryIDs.contains($0) } ?? false
        self.entries.removeAll { entryIDs.contains($0.id) }
        self.unshuffledOrder.removeAll { entryIDs.contains($0) }
        if removedSelection {
            self.currentEntryID = self.entries.isEmpty ? nil : self.entries[min(successorIndex, self.entries.count - 1)].id
            self.currentOccurrence = nil
            if wasActive { self.beginPlayback() }
        }
    }

    /// Uses the same destination-offset convention as a SwiftUI list move.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let valid = source.filter { self.entries.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let destination = min(max(0, destination), self.entries.count)
        let moving = valid.map { self.entries[$0] }
        let validSet = Set(valid)
        var reordered = self.entries.enumerated().filter { !validSet.contains($0.offset) }.map(\.element)
        let insertion = destination - valid.filter { $0 < destination }.count
        reordered.insert(contentsOf: moving, at: insertion)
        guard reordered.map(\.id) != self.entries.map(\.id) else { return }
        self.rememberEdit()
        self.entries = reordered
        // An explicit reorder becomes the order used when shuffle is turned off.
        self.unshuffledOrder = reordered.map(\.id)
    }

    public mutating func setShuffle(_ enabled: Bool) {
        var generator = SystemRandomNumberGenerator()
        self.setShuffle(enabled, using: &generator)
    }

    public mutating func setShuffle<R: RandomNumberGenerator>(_ enabled: Bool, using generator: inout R) {
        guard enabled != self.isShuffled else { return }
        self.rememberEdit()
        if enabled {
            self.unshuffledOrder = self.entries.map(\.id)
            self.shuffleUpcoming(using: &generator)
        } else {
            let byID = Dictionary(uniqueKeysWithValues: self.entries.map { ($0.id, $0) })
            self.entries = self.unshuffledOrder.compactMap { byID[$0] }
        }
        self.isShuffled = enabled
    }

    /// Restores the last queue edit while retaining the current entry if it still exists.
    @discardableResult
    public mutating func undo() -> Bool {
        guard let prior = self.undoHistory.popLast() else { return false }
        let selection = self.currentEntryID
        let occurrence = self.currentOccurrence
        self.entries = prior.entries
        self.unshuffledOrder = prior.unshuffledOrder
        self.isShuffled = prior.isShuffled
        if let selection, self.entries.contains(where: { $0.id == selection }) {
            self.currentEntryID = selection
            self.currentOccurrence = occurrence
        } else {
            self.currentEntryID = prior.selectedID ?? self.entries.first?.id
            self.currentOccurrence = nil
            if occurrence != nil { self.beginPlayback() }
        }
        return true
    }

    public mutating func updateTrack(_ track: Track) {
        for index in self.entries.indices where self.entries[index].track.id == track.id {
            self.entries[index].track = track
        }
    }

    public func snapshot(resumePosition: TimeInterval = 0) -> QueueSnapshot {
        QueueSnapshot(
            entries: self.entries,
            currentEntryID: self.currentEntryID,
            repeatMode: self.repeatMode,
            isShuffled: self.isShuffled,
            unshuffledOrder: self.unshuffledOrder,
            resumePosition: resumePosition.isFinite ? max(0, resumePosition) : 0
        )
    }

    private mutating func requestPlayback(of entry: QueueEntry) -> PlaybackOccurrence {
        self.generation &+= 1
        let occurrence = PlaybackOccurrence(
            sessionID: self.sessionID,
            entryID: entry.id,
            trackID: entry.track.id,
            generation: self.generation
        )
        self.currentEntryID = entry.id
        self.currentOccurrence = occurrence
        return occurrence
    }

    private mutating func rememberEdit() {
        guard self.undoLimit > 0 else { return }
        self.undoHistory.append(EditState(
            entries: self.entries,
            selectedID: self.currentEntryID,
            unshuffledOrder: self.unshuffledOrder,
            isShuffled: self.isShuffled
        ))
        if self.undoHistory.count > self.undoLimit {
            self.undoHistory.removeFirst(self.undoHistory.count - self.undoLimit)
        }
    }

    private mutating func shuffleUpcoming<R: RandomNumberGenerator>(using generator: inout R) {
        let start = self.currentIndex.map { $0 + 1 } ?? 0
        guard start < self.entries.count else { return }
        var upcoming = Array(self.entries[start...])
        upcoming.shuffle(using: &generator)
        self.entries.replaceSubrange(start..., with: upcoming)
    }
}
