# Desktop widget prerequisites

A desktop widget is not included in the current app. The menu bar player,
MiniPlayer and existing Shortcuts actions remain available. This document defines
the proposed first widget and the packaging work needed before implementing it.

## Native extension and shared data

Apple provides widgets through a separate
[WidgetKit extension](https://developer.apple.com/documentation/widgetkit/creating-a-widget-extension).
A SwiftUI window or the existing executable's App Intents metadata does not
supply that extension. The current Swift package and app packager produce one
application executable; they do not yet build, embed or validate an `.appex`.

The proposed extension reads a small snapshot written by the existing playback
owner. It never creates a player, signs in, requests service metadata or reads
the app's website store, credentials, queue or account-specific saved data.
Apple's [widget strategy](https://developer.apple.com/documentation/widgetkit/developing-a-widgetkit-strategy)
uses a shared app-group container for this exchange. Both targets need a tested
shared-container identity and matching configuration. Apple's
[app-group guidance](https://developer.apple.com/documentation/xcode/configuring-app-groups)
also documents a macOS naming scheme based on the developer team identifier.
The current ad-hoc app bundle does not establish that distribution boundary.

Before adding a production publisher, build a minimal extension with synthetic
data, embed it in the host app and verify registration and shared-container
access on both processor families. Establish the signing, entitlement and
installation path independently of compilation. Do not select an unregistered
team identifier, change existing profile storage, or substitute a public folder
for the group container.

## Proposed first behavior

The first version should show an optional public catalog-song title and artist,
with Open Player and explicit Play/Pause controls. Song details should be off
by default, with separate consent for exposing them outside the app. A generic
Open Player widget can remain useful when details are unavailable. Uploads,
episodes, unknown content and fallback metadata should produce that generic
state. Artwork and a progress clock can follow after the basic contract passes.

A bounded, versioned snapshot should include its creation and expiry times,
a random publication generation, playback occurrence and an opaque activation
token. It should exclude account names, account hashes, cookies, credentials,
history and the complete queue. Limits and schema validation apply before any
view or action is produced. Unsupported or expired snapshots show a generic
state. An expired entry must already be present in the timeline; a scheduled
reload alone cannot enforce expiry.

Pause, sign-out, account/profile changes and consent withdrawal should replace
the snapshot with a generic state and request a timeline reload. An accepted
write must belong to its original publication generation. A failed clear must
remain visible to the app and block further detail publication until resolved.
Previously rendered system snapshots may remain visible until the system
updates them; disabling cannot promise immediate removal of every cached view.
This limitation needs native acceptance before enabling private details.

## Actions and update budget

Apple's [interactive-widget guidance](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)
uses `AudioPlaybackIntent` for playback actions performed in the app process.
The existing app-process dispatcher is the integration point. A widget action
also needs its own captured activation/occurrence/publication token and expiry;
it must recheck the current owner before dispatch. Stale controls should open
the player or refuse the action, without selecting another profile, restoring
an old queue, starting another engine or waiting to run against a later state.

WidgetKit controls refresh timing and
[budgets timeline reloads](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date).
The app should publish on meaningful state changes and coalesce duplicate
updates. A widget must not depend on a polling loop or one reload per playback
sample. Any future elapsed-time display should use supported timeline rendering
with a bounded end state, rather than promise a continuously synchronized clock.

## Implementation order and acceptance

1. Add a minimal extension target and isolated synthetic packaging check. Verify
   the installed gallery entry, host/extension signatures, shared group access
   and relocated installation before connecting real playback state.
2. Add a pure snapshot schema, validation and stale-action tests. Exercise
   future versions, oversized input, invalid times, old generations and missing
   owners without touching actual profile storage.
3. Add a default-off publisher with revocation, atomic replacement, bounded
   storage and explicit error states. Cover held writes across consent changes,
   sign-out and profile replacement with disposable fixtures.
4. Connect native views and app-process actions. Check keyboard, VoiceOver,
   reduced transparency, lock/privacy behavior, app termination, stale entries,
   installation and removal on macOS 14 and supported newer systems.
5. Measure app and extension work, reload frequency, memory and idle behavior.
   Compilation or a SwiftUI preview does not establish a working desktop widget.

G33 remains missing. The extension package, distribution identity, snapshot
publisher and installed runtime checks are prerequisites, not shipped controls.
