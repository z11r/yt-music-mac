import AppKit

@main @MainActor
enum YTMusicMacLauncher {
    static func main() {
        // Leave the existing bundle diagnostic entry path unchanged.
        if !CommandLine.arguments.contains("--check-bundle") {
            _ = StartupWindowApplication.shared
        }
        YTMusicMacApp.main()
    }
}

/// Applies explicit startup choices to windows saved by older app versions too.
@objc(StartupWindowApplication)
@MainActor final class StartupWindowApplication: NSApplication {
    private var restorationGate = StartupWindowRestorationGate()

    func installStartupPolicy(_ policy: StartupWindowPolicy) {
        let supportsSelection: Bool
        if #available(macOS 15, *) { supportsSelection = true } else { supportsSelection = false }
        if restorationGate.install(policy, supportsSelection: supportsSelection) {
            SceneCheckDriver.current?.record("nativeRestorationPolicyInstalled")
        }
    }

    override func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier,
                                state: NSCoder,
                                completionHandler: @escaping (NSWindow?, (any Error)?) -> Void) -> Bool {
        SceneCheckDriver.current?.record("nativeWindowRestorationRequested")
        return restorationGate.resolveRestoration(native: {
            super.restoreWindow(withIdentifier: identifier, state: state,
                                completionHandler: completionHandler)
        }, decline: {
            SceneCheckDriver.current?.record("nativeWindowRestorationDeclined")
            completionHandler(nil, nil)
        })
    }
}
