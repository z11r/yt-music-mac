# Local audio foundation

Local-file playback is incomplete. The source model, private library store,
access contracts and service exclusions are implemented. There is no local-file
chooser, library screen or active local playback engine yet. Existing playback
controls continue to use the service player.

## Source and queue identity

A local track has `localFile` origin and a `LocalAudioReference` containing two
UUIDs: a library identifier and a file identifier. Its namespaced track identifier
does not identify a YouTube video. Duplicate queue entries retain separate entry
identifiers and playback occurrences.

Queue format 2 reads format 1 without changing queue order, shuffle order,
selection, resume position or existing service metadata. Loading never starts
playback. Invalid local references and future queue versions are refused; an
automatic save cannot replace an unreadable archive. Older app versions cannot
read format 2.

The `isWhollyLocal` validation entry point requires the expected profile, a valid
library and every referenced file record. It does not resolve files or change the
snapshot. Startup integration must preserve mixed queues on disk while service
session restoration is blocked. It must not silently filter service entries or
clear the sign-out fence to restore local files.

## Private library and file access

The library belongs to a local app profile, independently of a YouTube account.
Its bounded archive stores metadata, file identity and opaque bookmark data.
Tracks and queues carry neither file locations nor grants. The library permits
up to 2,000 records, 64 KiB per bookmark and 16 MiB per archive. Metadata fields,
duration and file size are validated. Writes compare the previous revision and
commit a private staging file atomically; malformed, future and foreign-profile
archives remain untouched.

The current unsandboxed build uses an explicit ordinary-bookmark mode. This mode
does not bypass file permissions. A separate read-only security-scoped mode is
available to a future entitled sandboxed build; a failed scoped grant never falls
back to ordinary access. No sandbox entitlements change in this implementation.
[Apple documents the sandbox boundary and required entitlements](https://developer.apple.com/documentation/professional-video-applications/enabling-security-scoped-bookmark-and-url-access).

Resolution requests no dialogs or volume mounting. The access adapter rejects
remote URLs, nonlocal volumes, aliases, symlinks, packages, unavailable cloud
files, unreadable files and changed file identities. Stale grants need an explicit
future Locate or Reauthorize action. No directory scanning, audio copying,
automatic downloads, file deletion or alternate-path search is provided.

A resource lease remains with the prepared asset and eventual player item until
all native users retire. Releasing it balances a successful scoped access exactly
once. Canceled callers retain the preparation admission until the underlying work
settles, preventing repeated actions from accumulating filesystem or asset work.

## Asset preparation and privacy

The inert native preparer uses asynchronous AVFoundation inspection and requires
playable, unprotected audio with a finite positive duration and no video track.
It does not create a player or play audio. It sets the
[external-reference policy](https://developer.apple.com/documentation/avfoundation/avurlassetreferencerestrictionskey)
to forbid all media outside the selected container and disables alias references.
Passing an extension check alone never establishes format support.

A local origin, any local reference or the reserved `local:` identifier namespace
excludes service playback, ratings,
radio, service playlist creation, song credits, lyrics requests, canonical links,
scrobbling, streaming metadata and public presence. This also applies to
inconsistent in-memory tracks with service-looking identifiers. Native drag and
portable service-link export refuse local tracks. Local artwork uses the native
placeholder, without a remote URL or YouTube thumbnail fallback.

## Remaining verification

Deterministic tests use temporary stores and fake bookmark, file and preparation
adapters. They establish migration, bounds, privacy exclusions, revision checks,
balanced leases and cancellation admission. They do not establish decoding,
audible playback, file grants or permission persistence.

The remaining implementation needs one shared transport owner with an awaited
WebKit retirement barrier, local engine integration, signed-out source handling,
native selection/recovery UI and profile shutdown wiring. Apple supports
[local media in AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer),
but actual format decoding, chooser permissions, relaunch access, seek/end/repeat,
device interruptions and service-to-local handoff still require synthetic asset
checks and packaged-app verification on Intel/macOS 14 and Apple silicon.
