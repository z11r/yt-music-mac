# Local app profiles

Settings → Local App Profiles can create, rename and switch between up to eight
profiles. A local profile keeps its YouTube sign-in, current queue, saved queues,
collection organization, song rules, episode progress, cache and settings
separate. It does not create a YouTube account.

The default profile retains the app's existing website-store identifier,
preferences, data folders and provider credential services. Additional profiles
use distinct website-store UUIDs, preference domains, local folders and provider
credential services. Account-specific records remain scoped to the confirmed
YouTube account within each profile. Profile names are display text; they never
become paths or service identifiers.

Switching pauses playback, disconnects the old session’s native controls and
waits for accepted local writes and playlist journals before activating another
session. Each window,
menu, notification observer, scripting command and Shortcut follows the current
activation. Playback starts paused after switching or relaunching. Appearance,
mini-player level, playback bindings, volume, autoplay and optional integrations
follow that profile. Launch at login and macOS notification permission are app
settings managed by the operating system.

New profiles start with automatic queue persistence, episode-progress
persistence, metadata caching, autoplay, library indexing, song notifications and
optional provider sharing off. Existing default-profile preferences retain their
previous behavior. An absent queue or episode persistence setting keeps the
legacy save-and-restore behavior.

## Local privacy controls

Settings → Local Privacy can stop automatic queue saves and restoration, stop
episode-progress persistence, and clear this app session's recent searches.
Turning a persistence setting off preserves existing files. Queued writes check
a revocable permission before writing; a write already in progress can finish.
Episode progress remains useful in memory while saving is off. Enabling saving
loads retained progress and merges newer in-memory records before future saves.
Explicitly saving or exporting a named queue remains a separate user action.

These controls do not pause, delete or hide YouTube history. Playback can still
appear in the signed-in account's service history. YouTube describes the watch
history shared by YouTube and YouTube Music and its pause/delete controls in
[its history help](https://support.google.com/youtubemusic/answer/6364666?hl=en).
Local profiles do not provide private listening.

## Recovery and limits

The bounded, versioned profile registry uses revision checks and atomic file
replacement. Malformed, oversized, unknown-field and future-version records are
retained. A missing registry uses the existing default profile without creating
additional profiles or writing a registry file. Only explicit create, rename or
switch actions change the registry.

Creation first saves a pending record. If setup fails, that bounded record stays
visible as Setup Incomplete and can be selected explicitly to retry. A selected
existing profile's missing website store is reported rather than recreated
silently. On switch preparation or selection-save failure, the prior usable session stays
paused, the saved selection is retained, and the main window and Settings show
the failure. Reload Profiles re-reads the registry; it does not erase it.
Profile deletion is unavailable pending a journaled cleanup workflow.

The separate website-store implementation uses the macOS 14
[WebKit profile APIs](https://webkit.org/blog/14423/building-profiles-with-new-webkit-api/).
Automated checks use memory registries, fake factories, permission gates and
isolated fixtures. They verify ownership order, failure recovery, stale
activation rejection, write suppression and resource translations. They do not
establish live multi-profile sign-in, persistent WebKit behavior, Keychain
isolation, window accessibility, or hardware playback. Those require an explicit
runtime check on an isolated app configuration.
