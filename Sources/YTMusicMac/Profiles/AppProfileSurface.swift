import SwiftUI

/// Recreates every window's content for each activation, even A → B → A.
/// Sheet state and AppStorage observers therefore cannot retain another owner.
struct AppProfileSurface<Content: View>: View {
    let runtime: NativeAppProfileRuntime
    let activationID: UUID
    let isSwitching: Bool
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(NativeControlAccent.preferenceKey) private var rawAccent = "system"
    @AppStorage(CustomControlAccent.preferenceKey) private var rawCustomAccent = ""
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder let content: () -> Content

    init(runtime: NativeAppProfileRuntime, activationID: UUID, isSwitching: Bool,
         @ViewBuilder content: @escaping () -> Content) {
        self.runtime = runtime; self.activationID = activationID; self.isSwitching = isSwitching
        self.content = content
        _appearance = AppStorage(wrappedValue: "system", "appearance", store: runtime.preferences)
        _rawAccent = AppStorage(wrappedValue: "system", NativeControlAccent.preferenceKey, store: runtime.preferences)
        _rawCustomAccent = AppStorage(wrappedValue: "", CustomControlAccent.preferenceKey, store: runtime.preferences)
    }
    var body: some View {
        content().id(activationID).disabled(isSwitching)
            .environment(\.allowsProfileArtworkLoading, !isSwitching)
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
            .tint(controlTint)
            .overlay { if isSwitching { ProgressView("Switching Profile…").padding().background(.regularMaterial) } }
    }
    private var controlTint: Color? {
        let dark = appearance == "dark" || (appearance != "light" && colorScheme == .dark)
        if let rgb = NativeControlAccent.customRGB(storedValue: rawAccent, customStoredValue: rawCustomAccent,
            increasedContrast: contrast == .increased, darkAppearance: dark) { return rgb.color }
        return NativeControlAccent.effective(storedValue: rawAccent, customStoredValue: rawCustomAccent,
            increasedContrast: contrast == .increased).tint
    }

}

actor InitialOnlyAppProfileRegistry: AppProfileRegistry {
    func load() -> AppProfileRegistrySnapshot { .init(archive: .original, revision: nil) }
    func save(_ archive: AppProfileArchive, replacing revision: Data?) throws -> AppProfileRegistrySnapshot {
        throw AppProfileError.unavailable
    }
}
