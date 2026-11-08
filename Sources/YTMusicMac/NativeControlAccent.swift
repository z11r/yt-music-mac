import AppKit
import SwiftUI

/// Optional native control tint. The system retains backgrounds, text, selection
/// styling and accessibility behavior; these choices contain no fixed RGB values.
enum NativeControlAccent: String, CaseIterable, Sendable, Identifiable {
    case system, blue, purple, teal

    static let preferenceKey = "nativeControlAccent"
    var id: String { rawValue }

    init(storedValue: Any?) {
        self = (storedValue as? String).flatMap(Self.init(rawValue:)) ?? .system
    }

    var title: String {
        switch self {
        case .system: AppLocalization.text("System Accent")
        case .blue: AppLocalization.text("Blue")
        case .purple: AppLocalization.text("Purple")
        case .teal: AppLocalization.text("Teal")
        }
    }

    static func effective(storedValue: Any?, increasedContrast: Bool) -> Self {
        increasedContrast ? .system : Self(storedValue: storedValue)
    }

    @MainActor var tint: Color? {
        switch self {
        case .system: nil
        case .blue: Color(nsColor: .systemBlue)
        case .purple: Color(nsColor: .systemPurple)
        case .teal: Color(nsColor: .systemTeal)
        }
    }
}

/// Uses only the supplied profile's preferences. Reads and accessibility
/// fallbacks never repair or rewrite an unknown stored value.
enum NativeControlAccentPreference {
    static func read(from preferences: UserDefaults, increasedContrast: Bool = false) -> NativeControlAccent {
        .effective(storedValue: preferences.object(forKey: NativeControlAccent.preferenceKey), increasedContrast: increasedContrast)
    }

    @MainActor @discardableResult
    static func write(_ accent: NativeControlAccent, to preferences: UserDefaults,
                      expectedGeneration: UUID, currentGeneration: UUID, acceptsActions: Bool) -> Bool {
        guard acceptsActions, expectedGeneration == currentGeneration else { return false }
        if accent == .system { preferences.removeObject(forKey: NativeControlAccent.preferenceKey) }
        else { preferences.set(accent.rawValue, forKey: NativeControlAccent.preferenceKey) }
        return true
    }
}
