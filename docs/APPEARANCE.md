# Native appearance

Settings → Appearance keeps the existing System, Light and Dark choices. Control
Accent adds optional System Accent, Blue, Purple, Teal or Custom Accent tint for supported
native controls. System Accent is the default. Each local profile stores its
own choice, and all profile windows receive it through their shared surface.

The named choices use AppKit's dynamic system colors. They add no fixed RGB
palette, custom backgrounds or text colors. With Increase Contrast enabled,
the tint override becomes `nil`, so native controls use the system accent.
The chosen preference remains stored for standard contrast. Unknown preference
values also fall back to the system accent without being rewritten.

The effect depends on each native control's style. A prominent collection Play
button can use the tint, while ordinary bordered buttons, text, artwork and the
service player retain their own styling. Color is not used to introduce a new
playback state or action. Theme selection adds no animation, timers, artwork
requests or playback changes; Reduce Motion continues to govern existing views.
Profile switches recreate the preference observers, and inactive or stale
settings actions cannot write a new choice.

## Custom Accent

Choose Custom Accent or Edit Custom Accent to prepare one opaque sRGB color for
Light and another for Dark. Native color wells and six-digit hexadecimal fields
edit the same draft. Apply saves the pair and selects Custom Accent; Cancel
leaves preferences unchanged. Named and System choices retain the saved pair for
reuse. Each local profile owns its own pair, and stale or already-consumed drafts
cannot write preferences.

The draft checks a 4.5:1 reference contrast against white for Light and black for
Dark, using the sRGB relative-luminance formula. These reference colors are not a
measurement of native controls, translucent materials, artwork, or every display.
Passing this check does not establish native accessibility conformance. Increase
Contrast uses the inherited system tint without rewriting the saved pair.

The pair is one bounded versioned scalar. Unknown versions, malformed values,
nonopaque colors and invalid components cannot become a custom tint. Reading an
unsupported stored pair does not repair or erase it; selecting that custom
accent uses the system fallback. Explicit Apply replaces it with the reviewed draft. The custom
accent adds no theme files, background processing or network access.

## Design sources

Apple recommends adaptable system colors, adequate contrast in both appearances,
and additional cues when color carries meaning. See [Color](https://developer.apple.com/design/human-interface-guidelines/color)
and [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility).
The implementation uses the macOS 12-and-later SwiftUI
[`tint(_:)`](https://developer.apple.com/documentation/swiftui/view/tint(_:))
API, whose effect varies with the native control style. Apple also documents
[`accessibilityReduceMotion`](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion)
for views that introduce motion. Its [ColorPicker](https://developer.apple.com/documentation/swiftui/colorpicker)
supports the system color panel on macOS 11 and later, with opacity controls
disabled for this workflow. The reference checks follow the
[W3C sRGB relative-luminance definition](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum).

The pinned Kaset source provides
[system/light/dark appearance selection](https://github.com/sozercan/kaset/blob/6a20e60c5dfd552a22e84f36daeef53f94f1ee41/Sources/Kaset/Models/AppAppearance.swift)
and separate [artwork-derived gradient backgrounds](https://github.com/sozercan/kaset/blob/6a20e60c5dfd552a22e84f36daeef53f94f1ee41/Sources/Kaset/Views/AccentBackground.swift).
This application's control accent uses native dynamic colors and the existing
profile-scoped surface; it imports no gradient or palette extraction code.

## Remaining checks

G52 is **Partial**. Deterministic checks cover preference validation, profile
isolation, rejected stale writes, contrast fallback, default tint and English
and French copy. Native visual contrast, keyboard access and VoiceOver remain
runtime acceptance checks in light and dark appearances, standard and increased
contrast, and with Reduce Motion enabled. Verify those combinations on the
macOS 14/Intel target and current Apple silicon before claiming accessibility
acceptance or resource measurements.

Whole-app themes and audio visualizers remain unimplemented. A
visualizer still needs an established service-compatible signal and measured
animation cost; this setting does not inspect or process protected audio.
This feature adds no audio-signal processing or hardware interaction.
