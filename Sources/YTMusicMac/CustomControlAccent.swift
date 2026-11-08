import AppKit
import Foundation
import Observation
import SwiftUI

struct CustomAccentRGB: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    init?(hex: String) {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard value.utf8.count == 6, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let number = UInt32(value, radix: 16) else { return nil }
        red = UInt8(number >> 16); green = UInt8((number >> 8) & 255); blue = UInt8(number & 255)
    }
    init?(red: Double, green: Double, blue: Double, opacity: Double) {
        guard [red, green, blue, opacity].allSatisfy({ $0.isFinite && (0...1).contains($0) }), opacity == 1 else { return nil }
        self.red = UInt8((red * 255).rounded()); self.green = UInt8((green * 255).rounded()); self.blue = UInt8((blue * 255).rounded())
    }
    var hex: String { String(format: "%02X%02X%02X", red, green, blue) }
    var luminance: Double {
        func linear(_ value: UInt8) -> Double {
            let component = Double(value) / 255
            return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
    var color: Color { Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, opacity: 1) }
    @MainActor init?(color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, opacity: rgb.alphaComponent)
    }
}

/// One versioned opaque pair. Reference contrast checks are not native-control certification.
struct CustomControlAccent: Equatable, Sendable {
    static let preferenceKey = "nativeCustomControlAccent"
    static let example = Self(light: CustomAccentRGB(hex: "0057B8")!, dark: CustomAccentRGB(hex: "7EB8FF")!)!
    let light: CustomAccentRGB
    let dark: CustomAccentRGB
    init?(light: CustomAccentRGB, dark: CustomAccentRGB) {
        guard (1.05 / (light.luminance + 0.05)) >= 4.5, ((dark.luminance + 0.05) / 0.05) >= 4.5 else { return nil }
        self.light = light; self.dark = dark
    }
    init?(storedValue: Any?) {
        guard let value = storedValue as? String, value.utf8.count == 16 else { return nil }
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0] == "v1", let light = CustomAccentRGB(hex: String(pieces[1])),
              let dark = CustomAccentRGB(hex: String(pieces[2])) else { return nil }
        self.init(light: light, dark: dark)
    }
    var storedValue: String { "v1:" + light.hex + ":" + dark.hex }
    func rgb(darkAppearance: Bool) -> CustomAccentRGB { darkAppearance ? dark : light }
}

@MainActor protocol NativeAccentPreferences {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}
extension UserDefaults: NativeAccentPreferences {}

@MainActor @Observable final class CustomAccentDraft: Identifiable {
    nonisolated let id = UUID()
    let generation: UUID
    private(set) var lightHex: String
    private(set) var darkHex: String
    private(set) var consumed = false
    init(storedValue: Any?, generation: UUID) {
        self.generation = generation
        let pair = CustomControlAccent(storedValue: storedValue) ?? .example
        lightHex = pair.light.hex; darkHex = pair.dark.hex
    }
    var pair: CustomControlAccent? {
        guard let light = CustomAccentRGB(hex: lightHex), let dark = CustomAccentRGB(hex: darkHex) else { return nil }
        return .init(light: light, dark: dark)
    }
    func accepts(currentGeneration: UUID, acceptsActions: Bool) -> Bool { !consumed && acceptsActions && generation == currentGeneration }
    func edit(_ text: String, dark: Bool, currentGeneration: UUID, acceptsActions: Bool) {
        guard text.utf8.count <= 32, accepts(currentGeneration: currentGeneration, acceptsActions: acceptsActions) else { return }
        if dark { darkHex = text } else { lightHex = text }
    }
    func apply(to preferences: any NativeAccentPreferences, currentGeneration: UUID, acceptsActions: Bool) -> Bool {
        guard accepts(currentGeneration: currentGeneration, acceptsActions: acceptsActions), let pair else { return false }
        consumed = true
        preferences.set(pair.storedValue, forKey: CustomControlAccent.preferenceKey)
        preferences.set(NativeControlAccent.custom.rawValue, forKey: NativeControlAccent.preferenceKey)
        return true
    }
    func cancel() { consumed = true }
}
