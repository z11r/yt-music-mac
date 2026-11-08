import AppKit
import AVKit
import SwiftUI

/// The system route picker, which lists AirPlay and other audio outputs.
///
/// Playback runs in WebKit, so there is no `AVPlayer` to attach. Without one
/// the picker offers the Mac's audio outputs rather than a route for a single
/// player.
struct AudioOutputPicker: NSViewRepresentable {
    static let label = "Audio Output"
    static let help = "Choose AirPlay speakers or another audio output."

    func makeNSView(context: Context) -> LabeledRoutePickerView {
        let picker = LabeledRoutePickerView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        picker.isRoutePickerButtonBordered = false
        picker.setRoutePickerButtonColor(.secondaryLabelColor, for: .normal)
        picker.setRoutePickerButtonColor(.labelColor, for: .normalHighlighted)
        picker.setRoutePickerButtonColor(.controlAccentColor, for: .active)
        picker.setRoutePickerButtonColor(.controlAccentColor, for: .activeHighlighted)
        picker.toolTip = "Choose Audio Output"
        return picker
    }

    func updateNSView(_ picker: LabeledRoutePickerView, context: Context) {}
}

/// The picker itself is the accessibility element (a button) and supplies a
/// generic label from the system; name it like the app's other controls.
final class LabeledRoutePickerView: AVRoutePickerView {
    override func accessibilityLabel() -> String? { AudioOutputPicker.label }
    override func accessibilityHelp() -> String? { AudioOutputPicker.help }
}
