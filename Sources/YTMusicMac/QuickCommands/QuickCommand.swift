import Foundation
import MusicCore

enum QuickCommand: Equatable, Sendable {
    enum Destination: String, CaseIterable, Sendable {
        case home, explore, library, songs, albums, artists, followedArtists, playlists, liked, history, uploads, podcasts, yourPodcasts, savedEpisodes, queue
    }
    case play, pause, next, previous
    case open(Destination), search(String), timerMinutes(Int), timerEnd, timerOff
    case volume(Int), seek(Int), shuffle(Bool), repeatMode(RepeatMode)

    var needsStartup: Bool {
        switch self { case .pause, .volume, .timerMinutes, .timerOff, .open(.queue): false; default: true }
    }
}
enum QuickCommandIssue: Error, Equatable {
    case empty, tooLong, invalidCharacters, unsupported, playbackUsage, openUsage, searchUsage, timerUsage, volumeUsage, seekUsage, shuffleUsage, repeatUsage
    case stale, notReady, noQueue, noCurrentOccurrence, noNext, cannotSeek, seekOutOfRange, signIn
    var message: String {
        switch self {
        case .empty: AppLocalization.text("Enter a command or choose an example below.")
        case .tooLong: AppLocalization.text("Keep a command within 1,024 UTF-8 bytes and a search query within 500 characters.")
        case .invalidCharacters: AppLocalization.text("Use a single line without control characters.")
        case .unsupported: AppLocalization.text("Command not recognized. Use an exact command from the examples; free-form playback requests are unsupported.")
        case .playbackUsage: AppLocalization.text("Use play, pause, next, or previous without extra words. To find music, use search followed by the complete query.")
        case .openUsage: AppLocalization.text("Use open followed by one listed destination, such as home, songs, artists, followed artists, uploads, or queue.")
        case .searchUsage: AppLocalization.text("Use search followed by a space and the complete query. Search results do not start playback.")
        case .timerUsage: AppLocalization.text("Use timer 1–1440 min, timer end, or timer off.")
        case .volumeUsage: AppLocalization.text("Use volume followed by a whole number from 0 to 100.")
        case .seekUsage: AppLocalization.text("Use seek m:ss, with 0–1440 minutes and 00–59 seconds.")
        case .shuffleUsage: AppLocalization.text("Use shuffle on or shuffle off.")
        case .repeatUsage: AppLocalization.text("Use repeat off, repeat all, or repeat one.")
        case .stale: AppLocalization.text("The account, startup intent, input, or palette changed. Review the current command and open Quick Commands again.")
        case .notReady: AppLocalization.text("Wait for startup or account confirmation to finish, then try again.")
        case .noQueue: AppLocalization.text("There are no queued songs to play. Open a collection or search, then choose playback explicitly.")
        case .noCurrentOccurrence: AppLocalization.text("No recording is currently active. Start playback before using this command.")
        case .noNext: AppLocalization.text("There is no next queued song.")
        case .cannotSeek: AppLocalization.text("The current recording has no confirmed duration to seek within.")
        case .seekOutOfRange: AppLocalization.text("Choose a position within the current recording's duration.")
        case .signIn: AppLocalization.text("Sign in through Account before playing the queue.")
        }
    }
}

/// Only fixed verbs/arguments are normalized. The complete remainder after one
/// search delimiter is opaque: no mood extraction, splitting, or fuzzy fallback.
enum QuickCommandParser {
    static func parse(_ input: String) -> Result<QuickCommand, QuickCommandIssue> {
        guard !input.isEmpty else { return .failure(.empty) }
        guard input.utf8.count <= 1_024 else { return .failure(.tooLong) }
        guard !input.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return .failure(.invalidCharacters) }
        let start = input.drop(while: { $0 == " " })
        guard !start.isEmpty else { return .failure(.empty) }
        let split = start.firstIndex(of: " ") ?? start.endIndex
        let verb = normalize(String(start[..<split]))
        let remainder = split == start.endIndex ? "" : String(start[start.index(after: split)...])
        if ["search", "rechercher", "recherche"].contains(verb) {
            guard !remainder.trimmingCharacters(in: .whitespaces).isEmpty else { return .failure(.searchUsage) }
            guard remainder.count <= 500 else { return .failure(.tooLong) }
            return .success(.search(remainder))
        }
        let words = remainder.split(separator: " ").map { normalize(String($0)) }
        let playback: [String: QuickCommand] = ["play": .play, "lire": .play, "pause": .pause, "next": .next, "suivant": .next, "previous": .previous, "precedent": .previous]
        if let command = playback[verb] { return words.isEmpty ? .success(command) : .failure(.playbackUsage) }
        switch verb {
        case "open", "ouvrir":
            let argument = words.joined(separator: " ")
            let destinations: [String: QuickCommand.Destination] = [
                "home": .home, "accueil": .home, "explore": .explore, "explorer": .explore,
                "library": .library, "bibliotheque": .library, "songs": .songs, "titres": .songs,
                "albums": .albums, "artists": .artists, "artistes": .artists,
                "followed artists": .followedArtists, "artistes suivis": .followedArtists,
                "playlists": .playlists, "listes": .playlists, "liked": .liked, "favoris": .liked,
                "history": .history, "historique": .history, "uploads": .uploads, "imports": .uploads,
                "podcasts": .podcasts, "balados": .podcasts, "your podcasts": .yourPodcasts, "vos balados": .yourPodcasts,
                "saved episodes": .savedEpisodes, "episodes enregistres": .savedEpisodes, "queue": .queue, "file": .queue]
            return destinations[argument].map { .success(.open($0)) } ?? .failure(.openUsage)
        case "timer", "minuterie":
            if words == ["off"] || words == ["arret"] { return .success(.timerOff) }
            if words == ["end"] || words == ["fin"] { return .success(.timerEnd) }
            guard words.count == 2, words[1] == "min", let value = integer(words[0], range: 1...1_440) else { return .failure(.timerUsage) }
            return .success(.timerMinutes(value))
        case "volume":
            guard words.count == 1, let value = integer(words[0], range: 0...100) else { return .failure(.volumeUsage) }
            return .success(.volume(value))
        case "seek", "position":
            guard words.count == 1 else { return .failure(.seekUsage) }
            let parts = words[0].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, parts[1].count == 2, let minutes = integer(parts[0], range: 0...1_440),
                  let seconds = integer(parts[1], range: 0...59) else { return .failure(.seekUsage) }
            return .success(.seek(minutes * 60 + seconds))
        case "shuffle", "aleatoire":
            if words == ["on"] || words == ["oui"] { return .success(.shuffle(true)) }
            if words == ["off"] || words == ["non"] { return .success(.shuffle(false)) }
            return .failure(.shuffleUsage)
        case "repeat", "repetition":
            if words == ["off"] || words == ["non"] { return .success(.repeatMode(.off)) }
            if words == ["all"] || words == ["toutes"] { return .success(.repeatMode(.all)) }
            if words == ["one"] || words == ["une"] { return .success(.repeatMode(.one)) }
            return .failure(.repeatUsage)
        default: return .failure(.unsupported)
        }
    }
    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func integer(_ value: String, range: ClosedRange<Int>) -> Int? {
        guard !value.isEmpty, value.utf8.count <= 4, value.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(value), range.contains(number) else { return nil }
        return number
    }
}
