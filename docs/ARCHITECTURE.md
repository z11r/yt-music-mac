# Architecture

This is the design for the first prototype. The app target has not been added yet.

Use SwiftUI for the main window and AppKit for window behavior where needed.
Keep the music state separate from the interface, and keep YouTube-specific
requests and player scripts behind small interfaces.

## Starting point

Reuse the music-related parts of [Kaset](https://github.com/sozercan/kaset/tree/6a20e60c5dfd552a22e84f36daeef53f94f1ee41)
where they fit: authentication, response parsers, playback messages, and native
media controls. Begin with a small extraction of those parts. If they cannot be
separated without changing playback behavior, keep a larger music-only slice for
the prototype and reduce it after the regression tests pass.

Kaset already has fixes for playback navigation history and frequent progress
updates. Keep those fixes. A new interface alone will not reduce WebKit's work.
Record source revisions and preserve license notices for every imported module.

## Code layout

Start with two targets: `MusicCore` for models, queue rules, and persistence
interfaces; `YTMusicMac` for the app, services, and views. Use Swift Testing for
core tests. Split more targets only when that makes testing or ownership clearer.

| Part | Responsibility |
| --- | --- |
| App session | Own the player, signed-in session, library client, and window state |
| MusicCore | Track and queue-entry identities, shuffle/repeat rules, saved queue format |
| Library client | Search and browse requests, response parsing, pagination, account-scoped caches |
| Playback bridge | Own the persistent WKWebView, send commands, validate incoming events |
| Views | Render state and forward actions; no independent playback or authentication logic |
| Mac integration | Media keys, Now Playing, Dock commands, and compact player windows |

The main window has a library sidebar, content area, and persistent player bar.
The queue opens alongside the content. The menu bar and mini-player reuse the
same session; opening either must not create another playback engine.

## Playback and queue

Give each queue entry its own identifier, even when two entries refer to the
same song. Keep the requested entry, confirmed media identity, and load generation
separate. Reject old events after a skip, account switch, or player reload.
Process each track ending once.

Keep the player alive across navigation and window changes. Prefer in-page
transitions where the current player supports them. Use a bounded recovery path
when it does not, and expose a retry action if recovery fails.

Update progress in the controls that display it. Avoid invalidating the library
view every second. Cancel obsolete search and artwork requests, limit cache size
using decoded image cost, and stop decorative animation when it is not visible.

## Sessions and storage

Use a persistent WebKit data store for the app's session. Use Keychain for any
credential archive needed beyond that store. Keep debug and release identities
separate, including their storage and update configuration.

Do not clear a valid session after a temporary connection failure. Sign-out
must stop account work, clear stored credentials, and invalidate delayed replies
from the previous session. Tests use temporary stores and mock credentials.

Store settings and the saved queue locally with a versioned format. Restore the
queue without starting playback. Keep account data out of diagnostic exports.

## Service constraints

YouTube Music's internal interfaces can change without notice. Verify requests
and player events against the live service before implementing changes to them.
Keep the adaptation code contained so a service change does not require rewriting
the interface. Respect the account's playback restrictions; account support
remains unverified until tested.

## Interface references

- [Apple Music's queue](https://support.apple.com/guide/music/queue-your-songs-musb1e6d1c76/mac): next/later actions and reordering.
- [Apple Music shortcuts](https://support.apple.com/guide/music/keyboard-shortcuts-mus1019/mac): familiar commands and text-focus behavior.
- [Mooziac](https://github.com/shirkeharsh/mooziac): compact Mac controls and menu bar interactions.
- [Pear Desktop](https://github.com/pear-devs/pear-desktop): desktop integration and optional features to compare during testing.

These are references for behavior. Their published memory and battery figures
are not performance targets or measurements for this project.
