# Interface design

This is the planned interface for YT Music for Mac. Build the playback and account
flows before applying the layout. A working control must reflect the service's
actual state; unfinished actions stay out of the interface.

The reference layout has a library sidebar, search, artwork shelves, and a bottom
player. Keep that familiar structure and use Mac window controls, menus, selection,
and keyboard behavior. Apple recommends flexible windows and direct access to
commands through the menu bar. [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)

## Main window

Use a resizable window with a standard title bar and unified toolbar. Start near
1180 × 780 points and test down to 860 × 600. These are layout targets to validate,
not platform requirements. Restore window size and the selected destination.
Closing the main window should leave active playback running; reopening it should
show the same track and queue. Quit stops playback.

| Area | Planned behavior |
| --- | --- |
| Sidebar | Home, Search, and Library, followed by liked music and playlists when available. Use a native sidebar list, clear selection, and collapsible sections. Start around 240 points wide and allow resizing. |
| Toolbar | Standard sidebar toggle, back and forward when navigation history exists, global search, and account access. Disable commands that cannot run. |
| Content | Artwork shelves for Home; a responsive grid or track list for collections. Album artwork stays square; artist portraits can be circular. Music videos show a centered square from the video thumbnail, without letterbox bars. Use a clear heading and a short secondary label. |
| Player | Persistent bottom area with artwork, title, artist, transport, seek, volume, and queue access. Keep its size stable when metadata changes. |
| Queue | Optional trailing inspector with the current track and Up Next. Start around 300 points wide. Allow duplicate songs as separate entries and show the selected occurrence. |

Use the sidebar for navigation and keep it shallow. Offer Show Sidebar in the View
menu so people can restore it after hiding it. Honor the system sidebar size and
accent preferences. [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)

Use native toolbar search with the prompt “Search music.” Search covers the catalog;
a playlist filter must be labeled separately. Preserve the query while opening a
result and returning. Cancel obsolete requests and keep existing results visible
while updating them. [Searching](https://developer.apple.com/design/human-interface-guidelines/searching)

## Appearance

Support automatic, light, and dark appearance. Use semantic foreground and
background colors, with album art supplying most of the color. Keep toolbar symbols
monochrome unless color conveys a state. Selection, focus, and disabled states must
remain recognizable over bright artwork. [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)

Use the system font through SwiftUI text styles. Titles need a clear hierarchy;
track names and controls should remain readable at normal Mac viewing distance.
Use regular or medium body text, semibold headings, and monospaced digits for time.
Allow long names to wrap in content and truncate predictably in the player, with
the full name available to accessibility. Do not bundle system font files.
[Typography](https://developer.apple.com/design/human-interface-guidelines/typography)

Keep content surfaces simple. Reserve materials for navigation and controls, with
an opaque fallback when Reduce Transparency is enabled. Newer macOS versions can
use their standard Liquid Glass controls; album cards do not need individual glass
effects. Avoid animated background blur or continuous artwork motion.
[Materials](https://developer.apple.com/design/human-interface-guidelines/materials)

Start artwork grids around 160–190 points per cover, with consistent spacing and
stable placeholders. Reduce columns as the window narrows. The player must retain
play/pause, previous, next, track identity, and queue access at the minimum size;
move secondary actions into a menu before controls overlap.

## Playback and secondary windows

The seek slider shows elapsed and total time. Disable seeking when the duration is
unknown or the service cannot seek. While dragging, show the proposed time and send
the seek when the drag ends. Use a real slider with an accessible value. Playback
errors should leave the track visible and offer a useful recovery action.

Give queue rows Play, Play Next, Add to Queue, and Remove where supported. Provide
keyboard alternatives to drag reordering. Removing a queued occurrence must not
remove every copy of that song. Keep queue mutations tied to the selected entry.

The mini-player and menu bar controls share the main player's state and commands.
Opening or closing either must not create a new playback session. The mini-player
shows artwork, track identity, transport, and a way back to the main window. Keep
it a normal window by default; an optional Keep on Top setting can come later.

## Keyboard and accessibility

Put app commands in the menu bar, including Settings, Search, playback, queue,
sidebar visibility, and mini-player. Preserve standard editing and window
shortcuts. Command-F focuses search. Space toggles playback only when the focus
context permits it; typing a space in a text field or activating a focused control
must still work. Do not install a global keyboard hook for ordinary app shortcuts.
[Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards)

The [shortcut reference](KEYBOARD_SHORTCUTS.md) lists the implemented bindings.
Playback commands follow the key window's first responder and yield to text
editing, focused buttons, sheets, and web content. The same session actions serve
the menus, player controls, and macOS media keys.

Use native buttons, sliders, lists, and menus. Give icon buttons explicit labels
and state, keep focus indicators visible, and expose track title and artist as one
coherent row. Decorative artwork should not duplicate the spoken track name.
Announce meaningful playback changes without reading elapsed time every second.

Test VoiceOver, Full Keyboard Access, Increase Contrast, Reduce Transparency, and
Reduce Motion. Motion must not be the only way to communicate loading or playback.
Offer static feedback and keep focus stable when results arrive.
[Testing accessibility features](https://developer.apple.com/documentation/accessibility/testing-system-accessibility-features-in-your-app)

## Implementation order

1. Bind native controls to tested playback, authentication, search, and queue state.
2. Build the sidebar, toolbar search, and persistent player using standard controls.
3. Add collection views, track lists, queue inspector, and explicit loading, empty,
   offline, signed-out, and error states. Never populate a live screen with sample
   account data.
4. Add mini-player and menu bar views using the same state owner.
5. Check keyboard behavior, accessibility, resizing, and appearance before adding
   optional visual effects. Measure scrolling and idle playback with real content.

Use `NavigationSplitView` and a sidebar `List` for navigation, `.searchable` for
catalog search, and `.inspector` for the queue. `NavigationSplitView` is available
from macOS 13; inspectors are available from macOS 14. Use AppKit where window or
responder behavior needs it. [Search in SwiftUI](https://developer.apple.com/documentation/swiftui/adding-a-search-interface-to-your-app),
[Inspectors](https://developer.apple.com/documentation/swiftui/view/inspector(ispresented:content:))

The macOS 14 path must include every core action. Gate custom `glassEffect` use to
macOS 26 or later and retain ordinary system materials on older versions. API
availability does not establish runtime support; release claims require the
checks in [Compatibility](COMPATIBILITY.md).
[Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)

## UI acceptance checklist

- [ ] Browse, search, sign in, play, seek, change volume, and edit the queue using
  only the keyboard; all visible controls are reachable and labeled in VoiceOver.
- [ ] Search accepts spaces, punctuation, pasted text, and input methods without
  triggering playback commands. Changing results does not steal focus.
- [ ] The window works at the target minimum size, in full screen, and with the
  sidebar or queue hidden. Long titles and large sidebar text do not cover controls.
- [ ] Light and dark appearances, increased contrast, reduced transparency, and
  reduced motion remain usable. Artwork loading does not shift the layout.
- [ ] Closing and reopening the main window, mini-player, or queue preserves the
  current playback session and selected queue occurrence.
- [ ] Loading, no results, expired sign-in, offline playback failure, and retry each
  have an honest state and a working next action.
- [ ] The macOS 14 interface has the same playback and library actions as newer
  systems. Intel and Apple silicon results are recorded separately.
- [ ] Fast scrolling, a long queue, artwork loading, and idle playback are measured;
  visual effects do not introduce continuous work when nothing changes.
