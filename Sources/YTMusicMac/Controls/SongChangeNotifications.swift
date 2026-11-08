import AppKit
import MusicCore
import Observation
import UserNotifications

/// The playback facts that decide whether a song has changed.
struct SongPlaybackState: Equatable, Sendable {
    var selectedEntryID: UUID?
    var occurrence: PlaybackOccurrence?
    /// The requested song itself is playing: not buffering, not an ad, and
    /// its position has been reported by the page.
    var isConfirmedPlaying = false
    var track: Track?
}

/// Finds confirmed song changes. A change is a queue entry that starts
/// playing after a different one; restarting, retrying, or seeking within the
/// same entry is not a change.
struct SongChangeTracker: Sendable {
    private(set) var settledEntryID: UUID?

    /// Returns the entry to announce when this state confirms a new song.
    mutating func update(_ state: SongPlaybackState) -> UUID? {
        guard let occurrence = state.occurrence else {
            // Nothing is requested. The selected entry, such as a restored
            // queue's song, is already on screen; starting it is not a change.
            settledEntryID = state.selectedEntryID
            return nil
        }
        guard state.isConfirmedPlaying, occurrence.entryID != settledEntryID else { return nil }
        settledEntryID = occurrence.entryID
        return occurrence.entryID
    }
}

struct SongNotificationContent: Equatable, Sendable {
    static let identifier = "song-change"

    let title: String
    let subtitle: String
    let body: String

    init(_ track: Track) {
        title = track.title
        body = track.artist
        subtitle = track.album ?? ""
    }
}

enum SongNotificationAuthorization: Equatable, Sendable {
    case notDetermined, allowed, denied
}

/// The notification calls the app makes. Tests use a fake; the app uses the
/// system center, which needs an application bundle.
@MainActor
protocol SongNotificationCenter: AnyObject {
    func authorization() async -> SongNotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func post(_ content: SongNotificationContent) async throws
    func removeDelivered()
}

@MainActor
final class SystemSongNotificationCenter: SongNotificationCenter {
    /// `UNUserNotificationCenter` stops the process when it has no bundle,
    /// as in `swift run` or unit tests.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func authorization() async -> SongNotificationAuthorization {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized, .provisional: return .allowed
        default: return .denied
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
    }

    func post(_ content: SongNotificationContent) async throws {
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.subtitle = content.subtitle
        notification.body = content.body
        notification.sound = nil
        // One identifier: each song replaces the previous one in Notification Center.
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: SongNotificationContent.identifier, content: notification, trigger: nil))
    }

    func removeDelivered() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [SongNotificationContent.identifier])
    }
}

/// Posts a notification when a new song starts while another app is in front.
/// Off by default; permission is requested only when the user turns it on.
@MainActor @Observable
final class SongChangeNotifier {
    static let preferenceKey = "showsSongChangeNotifications"

    private(set) var isEnabled: Bool
    private(set) var authorization: SongNotificationAuthorization = .notDetermined
    private(set) var isRequesting = false
    private(set) var message: String?

    var isAvailable: Bool { center != nil }

    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let center: SongNotificationCenter?
    @ObservationIgnored private let state: @MainActor () -> SongPlaybackState
    @ObservationIgnored private let isAppActive: @MainActor () -> Bool
    @ObservationIgnored private let operations = ProfileOperationFence()
    @ObservationIgnored private var tracker = SongChangeTracker()
    @ObservationIgnored private var isObserving = false
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var ownershipID = UUID()
    @ObservationIgnored private var requestID: UUID?

    init(preferences: UserDefaults, center: SongNotificationCenter?,
         isAppActive: @escaping @MainActor () -> Bool = { NSApplication.shared.isActive },
         state: @escaping @MainActor () -> SongPlaybackState) {
        self.preferences = preferences
        self.center = center
        self.isAppActive = isAppActive
        self.state = state
        isEnabled = center != nil && preferences.bool(forKey: Self.preferenceKey)
        _ = tracker.update(state())
    }

    convenience init(session: AppSession, preferences: UserDefaults) {
        self.init(preferences: preferences,
                  center: SystemSongNotificationCenter.isAvailable ? SystemSongNotificationCenter() : nil) {
            [weak session] in session.map(SongPlaybackState.init) ?? SongPlaybackState()
        }
    }

    /// Follows playback through Observation; no timer or polling.
    func start() {
        guard !isObserving else { return }
        operations.resume()
        isStopped = false
        ownershipID = UUID()
        isObserving = true
        observe()
    }

    func stop() {
        operations.quiesce()
        isStopped = true; isObserving = false; ownershipID = UUID()
        requestID = nil; isRequesting = false
        center?.removeDelivered()
    }

    func waitForIdle() async { await operations.waitForIdle() }

    private func observe() {
        let owner = ownershipID
        withObservationTracking { _ = state() } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped, self.ownershipID == owner else { return }
                // Register again before posting so later changes are not missed.
                self.observe()
                await self.evaluate()
            }
        }
    }

    /// Checks the current state and posts when it confirms a new song.
    @discardableResult
    func evaluate() async -> Bool {
        guard operations.begin() else { return false }
        defer { operations.end() }
        let owner = ownershipID
        let current = state()
        guard !isStopped, let entryID = tracker.update(current), let track = current.track,
              isEnabled, !isAppActive(), let center else { return false }
        let authorization = await center.authorization()
        guard !isStopped, ownershipID == owner else { return false }
        if self.authorization != authorization { self.authorization = authorization }
        guard authorization == .allowed else {
            message = Self.deniedMessage
            return false
        }
        // The song may have changed again while permission was checked.
        guard !isStopped, ownershipID == owner, isEnabled, state().occurrence?.entryID == entryID else { return false }
        do {
            try await center.post(SongNotificationContent(track))
            guard !isStopped, ownershipID == owner else { center.removeDelivered(); return false }
            return true
        } catch {
            return false
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isStopped, operations.begin() else { return }
        defer { operations.end() }
        let id = UUID()
        requestID = id
        guard enabled else {
            isRequesting = false
            store(false)
            message = nil
            center?.removeDelivered()
            return
        }
        guard let center else {
            message = AppLocalization.text("Song notifications are available when the app runs from its application bundle.")
            return
        }
        isRequesting = true
        var result = await center.authorization()
        guard !isStopped, requestID == id else { return }
        if result == .notDetermined {
            do { result = try await center.requestAuthorization() ? .allowed : .denied }
            catch { result = .denied }
        }
        // A later change to the setting replaces this request.
        guard !isStopped, requestID == id else { return }
        isRequesting = false
        authorization = result
        store(result == .allowed)
        message = result == .allowed ? nil : Self.deniedMessage
    }

    /// Updates the permission shown in Settings, which can change in System Settings.
    func refreshAuthorization() async {
        guard operations.begin() else { return }
        defer { operations.end() }
        let owner = ownershipID
        guard !isStopped, let center else { return }
        let result = await center.authorization()
        guard !isStopped, ownershipID == owner else { return }
        authorization = result
        if isEnabled, result == .denied { message = Self.deniedMessage }
        else if result == .allowed { message = nil }
    }

    private func store(_ enabled: Bool) {
        isEnabled = enabled
        preferences.set(enabled, forKey: Self.preferenceKey)
    }

    static let deniedMessage = AppLocalization.format("Notifications for %@ are turned off in System Settings.", AppIdentity.displayName)

    static var settingsURL: URL? {
        var components = URLComponents(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        components?.queryItems = [URLQueryItem(name: "id", value: AppIdentity.identifier)]
        return components?.url
    }
}

extension SongPlaybackState {
    @MainActor
    init(_ session: AppSession) {
        let player = session.player
        self.init(selectedEntryID: session.queue.currentEntryID,
                  occurrence: session.queue.currentOccurrence,
                  isConfirmedPlaying: player.isPlaying && !player.isBuffering && player.hasConfirmedPosition,
                  track: session.currentTrack)
    }
}
