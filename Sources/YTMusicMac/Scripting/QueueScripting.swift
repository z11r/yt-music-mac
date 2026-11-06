import CoreFoundation
import Foundation
import MusicCore
import YouTubeMusic

enum QueueScriptingInput {
    static func videoIDs(_ value: Any?) -> [String]? {
        guard let values = value as? [Any], (1...100).contains(values.count) else { return nil }
        let ids = values.compactMap(ScriptingInput.videoID)
        guard ids.count == values.count, Set(ids).count <= 10 else { return nil }
        return ids
    }

    static func position(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let seconds = value.doubleValue
        return seconds.isFinite && (0...604_800).contains(seconds) ? seconds : nil
    }

    static func repeatMode(_ value: Any?) -> RepeatMode? {
        guard let value = value as? String else { return nil }
        return RepeatMode(rawValue: value)
    }
}

enum ScriptedQueueResolver {
    static func resolve(videoIDs: [String], timeout: Duration = .seconds(20),
                        search: @escaping @Sendable (String) async throws -> MusicPage) async throws -> [Track] {
        guard QueueScriptingInput.videoIDs(videoIDs) == videoIDs else { throw AppScriptingError.invalidVideoID }
        return try await withThrowingTaskGroup(of: [Track].self) { group in
            group.addTask {
                var resolved: [String: Track] = [:]
                for id in videoIDs where resolved[id] == nil {
                    try Task.checkCancellation()
                    let page = try await search(id)
                    try Task.checkCancellation()
                    guard let track = page.tracks.first(where: { $0.id == id }) else {
                        throw AppScriptingError.trackNotFound
                    }
                    resolved[id] = track
                }
                return try videoIDs.map { id in
                    guard let track = resolved[id] else { throw AppScriptingError.trackNotFound }
                    return track
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AppScriptingError.lookupTimedOut
            }
            defer { group.cancelAll() }
            guard let tracks = try await group.next() else { throw AppScriptingError.lookupFailed }
            return tracks
        }
    }
}

struct ScriptingPlaybackSnapshot: Encodable {
    let player: ScriptingPlayerInfo
    let entryID: UUID?
    let occurrenceGeneration: String?
    let queueIndex: Int?
    let repeatMode: RepeatMode
    let shuffled: Bool

    @MainActor init(session: AppSession) {
        player = ScriptingPlayerInfo(session: session)
        entryID = session.queue.currentEntryID
        occurrenceGeneration = session.queue.currentOccurrence.map { String($0.generation) }
        queueIndex = session.queue.currentIndex
        repeatMode = session.queue.repeatMode
        shuffled = session.queue.isShuffled
    }

    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
