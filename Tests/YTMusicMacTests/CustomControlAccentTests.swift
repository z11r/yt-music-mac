import Foundation
import Testing
@testable import YTMusicMac

@MainActor struct CustomControlAccentTests {
    @Test func customEditorAndValidationCopyHaveEnglishAndFrenchResources() throws {
        let keys = ["Apply", "Custom Accent", "Edit Custom Accent…", "Light Accent", "Dark Accent",
            "Choose opaque sRGB accents for Light and Dark. Changes stay in this draft until Apply.",
            "Reference checks require 4.5:1 against white for Light and black for Dark. They do not certify the contrast of native controls.",
            "Use six hexadecimal digits. Choose a darker Light accent and a lighter Dark accent to pass the reference checks.",
            "The profile changed. Close this draft and open Custom Accent again.",
            "The saved custom accent is unsupported. It is retained until you explicitly replace it with Apply."]
        for language in ["en", "fr"] {
            let url = try #require(AppLocalization.bundle.url(forResource: language, withExtension: "lproj"))
            let bundle = try #require(Bundle(url: url))
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: "MISSING", table: "Localizable")
                #expect(value != "MISSING")
                if language == "fr" { #expect(value != key) }
            }
        }
    }
    @Test func hexAndComponentAdmissionRejectsOpacityHDRNonfiniteAndMalformedValues() {
        for value in ["", "fff", "#12345678", " 123456", "１２３４５６", "../red", "12345G", "123456\0"] { #expect(CustomAccentRGB(hex: value) == nil) }
        #expect(CustomAccentRGB(hex: "#aBc123")?.hex == "ABC123")
        for components in [(Double.nan, 0.0, 0.0, 1.0), (1.01, 0, 0, 1), (-0.01, 0, 0, 1), (0, 0, 0, 0.5), (0, 0, 0, Double.infinity)] {
            #expect(CustomAccentRGB(red: components.0, green: components.1, blue: components.2, opacity: components.3) == nil)
        }
        #expect(CustomAccentRGB(red: 0, green: 1, blue: 0, opacity: 1)?.hex == "00FF00")
    }
    @Test func referenceContrastUsesUnroundedSRGBAndDoesNotAcceptExtremes() throws {
        let black = try #require(CustomAccentRGB(hex: "000000")), white = try #require(CustomAccentRGB(hex: "FFFFFF"))
        #expect(black.luminance == 0 && abs(white.luminance - 1) < 1e-12)
        #expect(CustomControlAccent(light: white, dark: black) == nil)
        #expect(CustomControlAccent(light: black, dark: white) != nil)
        #expect(CustomControlAccent(light: CustomAccentRGB(hex: "777777")!, dark: white) == nil)
        #expect(CustomControlAccent(light: CustomAccentRGB(hex: "767676")!, dark: white) != nil)
        #expect(CustomControlAccent(light: black, dark: CustomAccentRGB(hex: "747474")!) == nil)
        #expect(CustomControlAccent(light: black, dark: CustomAccentRGB(hex: "757575")!) != nil)
        #expect(abs(CustomAccentRGB(hex: "0A0A0A")!.luminance - 0.003035269835488375) < 1e-12)
    }
    @Test func versionedAtomicPairRejectsUnknownVersionsAndRetainsMalformedBytesOnRead() {
        let preferences = MemoryAccentPreferences()
        let invalid: [Any] = ["v2:0057B8:7EB8FF", "v1:FFFFFF:000000", "v1:0057B8:7EB8FF:extra", "custom", 42, Data([1]), ["light": "0057B8"]]
        for value in invalid {
            preferences.values = [NativeControlAccent.preferenceKey: "custom", CustomControlAccent.preferenceKey: value]
            #expect(CustomControlAccent(storedValue: value) == nil)
            #expect(NativeControlAccentPreference.read(from: preferences) == .system)
            #expect(preferences.writes == 0)
            #expect(NSDictionary(dictionary: preferences.values).isEqual(to: [NativeControlAccent.preferenceKey: "custom", CustomControlAccent.preferenceKey: value]))
        }
        let pair = CustomControlAccent.example
        #expect(pair.storedValue == "v1:0057B8:7EB8FF" && CustomControlAccent(storedValue: pair.storedValue) == pair)
    }
    @Test func appearanceAndContrastFallbackArePureAndDoNotRewriteThePair() {
        let preferences = MemoryAccentPreferences(), pair = CustomControlAccent.example
        preferences.values = [NativeControlAccent.preferenceKey: "custom", CustomControlAccent.preferenceKey: pair.storedValue]
        #expect(NativeControlAccentPreference.read(from: preferences) == .custom)
        for dark in [true, false] {
            #expect(NativeControlAccent.customRGB(storedValue: "custom", customStoredValue: pair.storedValue, increasedContrast: false, darkAppearance: dark) == pair.rgb(darkAppearance: dark))
            #expect(NativeControlAccent.customRGB(storedValue: "custom", customStoredValue: pair.storedValue, increasedContrast: true, darkAppearance: dark) == nil)
        }
        #expect(NativeControlAccentPreference.read(from: preferences, increasedContrast: true) == .system)
        #expect(preferences.writes == 0)
    }
    @Test func draftApplyIsExplicitOnceOnlyAndNamedChoicesRetainTheSavedPair() {
        let preferences = MemoryAccentPreferences(), generation = UUID()
        let draft = CustomAccentDraft(storedValue: nil, generation: generation)
        draft.edit("112233", dark: false, currentGeneration: generation, acceptsActions: true)
        #expect(preferences.values.isEmpty)
        let applied = draft.apply(to: preferences, currentGeneration: generation, acceptsActions: true)
        #expect(applied)
        #expect(preferences.writes == 2 && NativeControlAccentPreference.read(from: preferences) == .custom)
        let pair = preferences.string(forKey: CustomControlAccent.preferenceKey)
        let reapplied = draft.apply(to: preferences, currentGeneration: generation, acceptsActions: true)
        #expect(!reapplied)
        draft.edit("000000", dark: false, currentGeneration: generation, acceptsActions: true)
        #expect(draft.lightHex == "112233" && preferences.writes == 2)
        #expect(NativeControlAccentPreference.write(.system, to: preferences, expectedGeneration: generation, currentGeneration: generation, acceptsActions: true))
        #expect(preferences.string(forKey: CustomControlAccent.preferenceKey) == pair)
        #expect(NativeControlAccentPreference.write(.custom, to: preferences, expectedGeneration: generation, currentGeneration: generation, acceptsActions: true))
    }
    @Test func cancelInvalidDraftOversizedEditsAndStaleOwnersCannotWrite() {
        let preferences = MemoryAccentPreferences(), generation = UUID()
        let draft = CustomAccentDraft(storedValue: nil, generation: generation)
        draft.edit(String(repeating: "x", count: 33), dark: false, currentGeneration: generation, acceptsActions: true)
        #expect(draft.lightHex == CustomControlAccent.example.light.hex)
        draft.edit("FFFFFF", dark: false, currentGeneration: generation, acceptsActions: true)
        let reapplied = draft.apply(to: preferences, currentGeneration: generation, acceptsActions: true)
        #expect(!reapplied)
        draft.edit("000000", dark: false, currentGeneration: UUID(), acceptsActions: true)
        #expect(draft.lightHex == "FFFFFF")
        draft.cancel()
        let canceled = draft.apply(to: preferences, currentGeneration: generation, acceptsActions: true)
        #expect(!canceled && preferences.writes == 0)
        let stale = CustomAccentDraft(storedValue: nil, generation: generation)
        let wrongOwner = stale.apply(to: preferences, currentGeneration: UUID(), acceptsActions: true)
        let quiesced = stale.apply(to: preferences, currentGeneration: generation, acceptsActions: false)
        #expect(!wrongOwner && !quiesced)
        #expect(preferences.values.isEmpty)
    }
    @Test func retainedEditorCallbacksShareOneCancellationAndConsumptionAuthority() {
        let preferences = MemoryAccentPreferences(), generation = UUID()
        let draft = CustomAccentDraft(storedValue: nil, generation: generation), retained = draft
        draft.cancel()
        retained.edit("112233", dark: false, currentGeneration: generation, acceptsActions: true)
        let canceled = retained.apply(to: preferences, currentGeneration: generation, acceptsActions: true)
        #expect(!canceled && retained.lightHex == CustomControlAccent.example.light.hex && preferences.writes == 0)
        let next = CustomAccentDraft(storedValue: nil, generation: generation), alias = next
        let applied = next.apply(to: preferences, currentGeneration: generation, acceptsActions: true)
        let repeated = alias.apply(to: preferences, currentGeneration: generation, acceptsActions: true)
        #expect(applied && !repeated && preferences.writes == 2)
    }
    @Test func independentProfileStoresAndCleanupAdmissionRemainNarrow() {
        let a = MemoryAccentPreferences(), b = MemoryAccentPreferences(), generation = UUID()
        let draft = CustomAccentDraft(storedValue: nil, generation: generation)
        let applied = draft.apply(to: a, currentGeneration: generation, acceptsActions: true)
        #expect(applied)
        #expect(b.values.isEmpty && b.writes == 0)
        #expect(ProfilePreferenceCleanup.accepts(a.values))
        #expect(!ProfilePreferenceCleanup.accepts(["nativeControlAccent": "custom"]))
        #expect(!ProfilePreferenceCleanup.accepts(["nativeCustomControlAccent": "v2:0057B8:7EB8FF"]))
        #expect(!ProfilePreferenceCleanup.accepts(["nativeCustomControlAccent": ["light": "0057B8"]]))
        #expect(!ProfilePreferenceCleanup.accepts(["nativeCustomControlAccent": "v1:0057B8:7EB8FF", "futureTheme": true]))
        #expect(!ProfilePreferenceCleanup.accepts(["startupWindowPolicy": "hidden"]))
    }
}
