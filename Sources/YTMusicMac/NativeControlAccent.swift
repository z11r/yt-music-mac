import AppKit
import SwiftUI

/// Optional native control tint. The system retains backgrounds, text, selection
/// styling and accessibility behavior; named choices use dynamic system colors.
enum NativeControlAccent: String, CaseIterable, Sendable, Identifiable {
    case system, blue, purple, teal, custom

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
        case .custom: AppLocalization.text("Custom Accent")
        }
    }

    static func effective(storedValue: Any?, customStoredValue: Any? = nil, increasedContrast: Bool) -> Self {
        guard !increasedContrast else { return .system }
        let choice = Self(storedValue: storedValue)
        return choice == .custom && CustomControlAccent(storedValue: customStoredValue) == nil ? .system : choice
    }
    static func customRGB(storedValue: Any?, customStoredValue: Any?, increasedContrast: Bool, darkAppearance: Bool) -> CustomAccentRGB? {
        guard effective(storedValue: storedValue, customStoredValue: customStoredValue, increasedContrast: increasedContrast) == .custom else { return nil }
        return CustomControlAccent(storedValue: customStoredValue)?.rgb(darkAppearance: darkAppearance)
    }

    @MainActor var tint: Color? {
        switch self {
        case .system, .custom: nil
        case .blue: Color(nsColor: .systemBlue)
        case .purple: Color(nsColor: .systemPurple)
        case .teal: Color(nsColor: .systemTeal)
        }
    }
}

/// Uses only the supplied profile's preferences. Reads and accessibility
/// fallbacks never repair or rewrite an unknown stored value.
@MainActor enum NativeControlAccentPreference {
    static func read(from preferences: any NativeAccentPreferences, increasedContrast: Bool = false) -> NativeControlAccent {
        .effective(storedValue: preferences.object(forKey: NativeControlAccent.preferenceKey), customStoredValue: preferences.object(forKey: CustomControlAccent.preferenceKey), increasedContrast: increasedContrast)
    }

    @MainActor @discardableResult
    static func write(_ accent: NativeControlAccent, to preferences: any NativeAccentPreferences,
                      expectedGeneration: UUID, currentGeneration: UUID, acceptsActions: Bool) -> Bool {
        guard acceptsActions, expectedGeneration == currentGeneration else { return false }
        guard accent != .custom || CustomControlAccent(storedValue: preferences.object(forKey: CustomControlAccent.preferenceKey)) != nil else { return false }
        if accent == .system { preferences.removeObject(forKey: NativeControlAccent.preferenceKey) }
        else { preferences.set(accent.rawValue, forKey: NativeControlAccent.preferenceKey) }
        return true
    }
}
