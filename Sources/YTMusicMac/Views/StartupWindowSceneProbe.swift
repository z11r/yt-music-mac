import AppKit
import SwiftUI

/// Only the isolated packaged scene check installs this probe.
struct StartupMiniWindowProbe: NSViewRepresentable {
    let driver: SceneCheckDriver
    func makeNSView(context: Context) -> Probe { Probe(driver: driver) }
    func updateNSView(_ view: Probe, context: Context) { driver.miniAttached(view.window) }
    final class Probe: NSView {
        let driver: SceneCheckDriver
        init(driver: SceneCheckDriver) { self.driver = driver; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); driver.miniAttached(window) }
    }
}
