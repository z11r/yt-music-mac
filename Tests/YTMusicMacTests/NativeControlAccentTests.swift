import Foundation
import Testing
@testable import YTMusicMac

@Suite("Scoped native control accents") @MainActor
struct NativeControlAccentTests {
    @Test func missingUnknownAndMalformedValuesFallBackWithoutRepairingPreferences() throws {
        let fixture = try AccentPreferences()
        defer { fixture.remove() }
        #expect(NativeControlAccentPreference.read(from: fixture.defaults) == .system)
        #expect(fixture.defaults.object(forKey: NativeControlAccent.preferenceKey) == nil)
        let invalid: [Any] = ["unknown", "BLUE", "", "../purple", 42, ["blue"], ["theme": "blue"]]
        for value in invalid {
            fixture.defaults.set(value, forKey: NativeControlAccent.preferenceKey)
            let before = fixture.defaults.persistentDomain(forName: fixture.domain) as NSDictionary?
            #expect(NativeControlAccentPreference.read(from: fixture.defaults) == .system)
            let after = fixture.defaults.persistentDomain(forName: fixture.domain) as NSDictionary?
            #expect(after == before)
        }
    }

    @Test func knownChoicesRoundTripAndSystemRemovesOnlyThisOverride() throws {
        let fixture = try AccentPreferences()
        defer { fixture.remove() }
        let generation = UUID()
        fixture.defaults.set("dark", forKey: "appearance")
        fixture.defaults.set("preserve", forKey: "other-setting")
        for choice in NativeControlAccent.allCases where choice != .system {
            #expect(NativeControlAccentPreference.write(choice, to: fixture.defaults,
                expectedGeneration: generation, currentGeneration: generation, acceptsActions: true))
            #expect(NativeControlAccentPreference.read(from: fixture.defaults) == choice)
        }
        #expect(NativeControlAccentPreference.write(.system, to: fixture.defaults,
            expectedGeneration: generation, currentGeneration: generation, acceptsActions: true))
        #expect(fixture.defaults.object(forKey: NativeControlAccent.preferenceKey) == nil)
        #expect(fixture.defaults.string(forKey: "appearance") == "dark")
        #expect(fixture.defaults.string(forKey: "other-setting") == "preserve")
    }

    @Test func increasedContrastNeverOverridesTheStoredChoiceAndDefaultAddsNoTint() throws {
        let fixture = try AccentPreferences()
        defer { fixture.remove() }
        #expect(NativeControlAccent.system.tint == nil)
        for choice in NativeControlAccent.allCases {
            fixture.defaults.set(choice.rawValue, forKey: NativeControlAccent.preferenceKey)
            #expect(NativeControlAccentPreference.read(from: fixture.defaults, increasedContrast: true) == .system)
            #expect(fixture.defaults.string(forKey: NativeControlAccent.preferenceKey) == choice.rawValue)
            #expect(NativeControlAccentPreference.read(from: fixture.defaults, increasedContrast: false) == choice)
            if choice != .system { #expect(choice.tint != nil) }
        }
    }

    @Test func profileStoresRemainIndependentAndStaleOrQuiescedActionsDoNotWrite() throws {
        let first = try AccentPreferences(), second = try AccentPreferences()
        defer { first.remove(); second.remove() }
        let oldA = UUID(), currentA = UUID(), currentB = UUID()
        #expect(NativeControlAccentPreference.write(.blue, to: first.defaults,
            expectedGeneration: currentA, currentGeneration: currentA, acceptsActions: true))
        #expect(NativeControlAccentPreference.write(.teal, to: second.defaults,
            expectedGeneration: currentB, currentGeneration: currentB, acceptsActions: true))
        #expect(!NativeControlAccentPreference.write(.purple, to: first.defaults,
            expectedGeneration: oldA, currentGeneration: currentA, acceptsActions: true))
        #expect(!NativeControlAccentPreference.write(.system, to: second.defaults,
            expectedGeneration: currentB, currentGeneration: currentB, acceptsActions: false))
        #expect(NativeControlAccentPreference.read(from: first.defaults) == .blue)
        #expect(NativeControlAccentPreference.read(from: second.defaults) == .teal)
    }

    @Test func everyNativeChoiceAndExplanationHasEnglishAndFrenchCopy() throws {
        let keys = ["System Accent", "Blue", "Purple", "Teal", "Control Accent",
                    "Sets the tint of supported native controls in this local profile.",
                    "Increase Contrast uses the system accent. Your chosen accent is kept for standard contrast."]
        for language in ["en", "fr"] {
            let path = try #require(AppLocalization.bundle.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: "MISSING", table: "Localizable")
                #expect(value != "MISSING")
                if language == "fr" { #expect(value != key) }
            }
        }
    }
}

private struct AccentPreferences {
    let domain = "NativeControlAccentTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    init() throws { defaults = try #require(UserDefaults(suiteName: domain)) }
    func remove() { defaults.removePersistentDomain(forName: domain) }
}
