/// How an occurrence entered the queue. This does not describe the recording's
/// catalog or upload identity, and never changes its playback identity.
public enum QueueEntryOrigin: String, Codable, Hashable, Sendable {
    case unknown, manual, radio, autoplay, recommendation
}
