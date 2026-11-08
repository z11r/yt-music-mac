import Foundation
import MusicCore

/// Only fixed native copy reaches playback state, automation or diagnostics.
enum LocalAudioPlaybackIssue: String, Error, CaseIterable, Equatable, Sendable, LocalizedError {
    case stale, busy, unavailable, permission, unsupported, notReady, timedOut, seekFailed, outputUnconfirmed, cancelled
    var errorDescription: String? {
        let key: String = switch self {
        case .stale: "This local audio request is no longer current."
        case .busy: "Local audio is busy. Wait for the previous operation to finish."
        case .unavailable: "This local audio file is unavailable. Locate it or choose another file."
        case .permission: "Access to this local audio file must be authorized again."
        case .unsupported: "This file cannot be used for local audio playback."
        case .notReady: "The local audio file is not ready."
        case .timedOut: "The local audio operation did not finish in time."
        case .seekFailed: "The local audio playback position could not be changed."
        case .outputUnconfirmed: "The previous audio output could not be confirmed stopped."
        case .cancelled: "The local audio operation was cancelled."
        }
        return AppIdentity.resourceBundle.localizedString(forKey: key, value: nil, table: "LocalAudio")
    }
    static func sanitizing(_ error: any Error) -> Self {
        if let issue = error as? Self { return issue }
        if error is CancellationError { return .cancelled }
        if let library = error as? LocalAudioLibraryError {
            switch library {
            case .wrongProfile, .wrongLibrary, .staleRevision: return .stale
            case .busy, .capacityReached: return .busy
            default: return .unavailable
            }
        }
        switch error as? LocalAudioAccessError {
        case .busy: return .busy
        case .staleBookmark, .accessDenied, .identityChanged: return .permission
        case .invalidURL, .unsafeFile, .unsupportedAsset, .unsupportedAccessMode: return .unsupported
        default: return .unavailable
        }
    }
}
