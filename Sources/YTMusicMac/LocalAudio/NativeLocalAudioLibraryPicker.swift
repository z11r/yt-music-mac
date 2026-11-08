import AppKit
import UniformTypeIdentifiers

/// Inert until an explicit controller action presents the panel.
@MainActor final class NativeLocalAudioLibraryPicker: LocalAudioLibraryFilePicking {
    private var panel: NSOpenPanel?
    private var completion: CheckedContinuation<[URL]?, Never>?
    private var request = UUID()

    func chooseFiles(multiple: Bool) async -> [URL]? {
        guard panel == nil else { return nil }
        let id = UUID(); request = id
        let panel = NSOpenPanel()
        panel.title = LocalAudioLibraryCopy.text("Choose Local Audio Files")
        panel.prompt = LocalAudioLibraryCopy.text("Review Files")
        panel.allowedContentTypes = [.audio]
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = multiple; panel.resolvesAliases = false
        panel.canCreateDirectories = false; panel.treatsFilePackagesAsDirectories = false
        self.panel = panel
        return await withCheckedContinuation { continuation in
            completion = continuation
            panel.begin { [weak self, weak panel] result in
                guard let self, self.request == id else { return }
                self.finish(result == .OK ? panel?.urls : nil)
            }
        }
    }
    func cancel() {
        let old = panel
        finish(nil); old?.cancel(nil)
    }
    private func finish(_ urls: [URL]?) {
        request = UUID(); panel = nil
        let pending = completion; completion = nil; pending?.resume(returning: urls)
    }
}
