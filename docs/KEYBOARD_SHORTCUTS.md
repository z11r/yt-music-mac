# Keyboard shortcuts

Playback shortcuts follow [Kaset](https://github.com/sozercan/kaset/blob/6a20e60c5dfd552a22e84f36daeef53f94f1ee41/docs/keyboard-shortcuts.md)
and [Music on Mac](https://support.apple.com/guide/music/keyboard-shortcuts-mus1019/mac).
The app menus show the available shortcuts.

| Default shortcut | Action |
| --- | --- |
| Space | Play or pause |
| ⌘→ / ⌘← | Next or previous song; Previous restarts after three seconds |
| ⌥⌘→ / ⌥⌘← | Seek forward or backward 10 seconds |
| ⌘↑ / ⌘↓ | Raise or lower app volume by 10 percentage points |
| ⌘S | Toggle shuffle |
| ⌘R | Cycle repeat: Off → All → One |
| ⌘1 / ⌘2 / ⌘3 / ⌘4 | Home / Explore / Library / Liked Songs |
| ⌘F | Focus search in the main window |
| ⇧⌘U | Show or hide the queue |
| ⇧⌘M | Show the mini-player |
| ⌘0 | Show the main window |

All playback shortcuts yield to text entry, including search. Space also yields to
focused buttons so keyboard navigation can activate them. Web content and sheets
keep playback keys for their own controls. Clicking a Playback menu command
remains available regardless of text focus.

⌘M minimizes, ⌘W closes the current window, ⌘Q quits, ⌘H hides, and ⌘, opens
Settings. Mute is available in the Playback menu without taking over ⌘M.
These shortcuts apply within the app. Media keys use macOS Now Playing controls.

## Customize playback bindings

Open Settings → Keyboard → Customize Playback Shortcuts. Each of the nine
playback actions can use a different binding or have its shortcut disabled.
Choose Edit, select a logical key and modifiers, then Save. The Playback menu
shows the active binding when the focused view permits it.

Custom bindings use letters, numbers, or arrows with Command or Control. The
existing Space default remains available for Play/Pause. Standard Mac editing,
window, accessibility, navigation, and app commands stay reserved. A conflict
names the action that already owns the combination, and saves nothing. Change
or disable that action before reusing its binding.

Use Default resets one action; Reset All Playback Shortcuts restores all nine.
Resetting an individual default can report a conflict if another action now owns
that key. Bindings are saved in this app's local preferences. Unreadable or newer
saved formats leave defaults active and retain the saved data until an explicit
save or reset.

Navigation, search, and window shortcuts remain fixed. No global hotkeys or
key-capture permission is needed. The native editor uses key and modifier menus.
Installed keyboard-only editing, VoiceOver, and alternate-layout checks remain
part of runtime acceptance.
