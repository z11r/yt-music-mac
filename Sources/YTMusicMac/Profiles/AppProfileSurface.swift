import SwiftUI

/// Recreates every window's content for each activation, even A → B → A.
/// Sheet state and AppStorage observers therefore cannot retain another owner.
struct AppProfileSurface<Content: View>: View {
    let runtime: NativeAppProfileRuntime
    let activationID: UUID
    let isSwitching: Bool
    @AppStorage("appearance") private var appearance = "system"
    @ViewBuilder let content: () -> Content

    init(runtime: NativeAppProfileRuntime, activationID: UUID, isSwitching: Bool,
         @ViewBuilder content: @escaping () -> Content) {
        self.runtime = runtime; self.activationID = activationID; self.isSwitching = isSwitching
        self.content = content
        _appearance = AppStorage(wrappedValue: "system", "appearance", store: runtime.preferences)
    }
    var body: some View {
        content().id(activationID).disabled(isSwitching)
            .environment(\.allowsProfileArtworkLoading, !isSwitching)
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
            .overlay { if isSwitching { ProgressView("Switching Profile…").padding().background(.regularMaterial) } }
    }
}

actor InitialOnlyAppProfileRegistry: AppProfileRegistry {
    func load() -> AppProfileRegistrySnapshot { .init(archive: .original, revision: nil) }
    func save(_ archive: AppProfileArchive, replacing revision: Data?) throws -> AppProfileRegistrySnapshot {
        throw AppProfileError.unavailable
    }
}
