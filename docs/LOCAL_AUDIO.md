# Local audio files

Open **View → Open Local Audio…** to choose audio files, review their metadata,
and save their locations in the current local profile. Select saved files and
choose **Add to Queue** or **Play Selection**. Local files do not require a YouTube
account. The existing app queue and transport own playback for both local files
and service entries.

The library, native AVFoundation adapter and app integration are implemented.
Deterministic checks use fake output and file-access adapters; actual decoding,
permissions and audible playback remain packaged-app acceptance checks.
See the [library controls](LOCAL_AUDIO_LIBRARY.md) and
[engine ownership](LOCAL_AUDIO_ENGINE.md) for their contracts.

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
snapshot. While service session restoration is blocked, startup restores only a
validated, wholly local queue and leaves it paused. Mixed or service queues stay
unexposed on disk. After signing in, **Review Saved Queue…** offers an explicit,
paused restore: the account that saved an older archive cannot be verified.
Confirming replaces the current queue. Adding a new queue intentionally replaces
the retained archive; startup never silently filters service entries.

## Private library and file access

The library belongs to a local app profile, independently of a YouTube account.
Its bounded archive stores metadata, file identity and opaque bookmark data.
Tracks and queues carry neither file locations nor grants. The library permits
up to 2,000 records, 64 KiB per bookmark and 16 MiB per archive. Metadata fields,
duration and file size are validated. Writes compare the previous revision and
commit a private staging file atomically; malformed, future and foreign-profile
archives remain untouched. A stable private lock file coordinates writers across
app processes. Its exclusive OS lock is nonblocking and stays held from the
current archive read through replacement. Lock files remain in place on release.

The current unsandboxed build uses an explicit ordinary-bookmark mode. This mode
does not bypass file permissions. A separate read-only security-scoped mode is
available to a future entitled sandboxed build; a failed scoped grant never falls
back to ordinary access. No sandbox entitlements change in this implementation.
[Apple documents the sandbox boundary and required entitlements](https://developer.apple.com/documentation/professional-video-applications/enabling-security-scoped-bookmark-and-url-access).

Resolution requests no dialogs, volume mounting or implicit security access;
the resource lease owns each explicit access interval. The access adapter rejects
remote URLs, nonlocal volumes, aliases, symlinks, packages, unavailable cloud
files, unreadable files and changed file identities. Stale grants need an explicit
Locate or Reauthorize action. No directory scanning, audio copying,
automatic downloads, file deletion or alternate-path search is provided. Encoded
NUL bytes are refused before file inspection; a literal percent filename remains
valid.

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
inconsistent in-memory tracks with service-looking identifiers. Automation status
omits the service identifier for local sources while keeping transport state and
queue counts. Native drag and
portable service-link export refuse local tracks. Local artwork uses the native
placeholder, without a remote URL or YouTube thumbnail fallback.

## Transport and profile changes

Each session owns one source-neutral transport. Starting another source first
revokes the old engine's controls, closes media presentations and awaits a bounded
native quiet receipt. Uncertain output blocks the replacement and profile
activation. A late quiet receipt releases admission; it never restarts an old
request. Web playback uses a fresh engine after permanent retirement.

Pause, volume, seek, queue navigation, repeat and sleep timers use the same queue
occurrences. Local preparation installs paused and checks the latest user intent
before starting. Canceled file or asset work retains its actual resource leases,
with bounded operation counts; it cannot hold Web output after the old engine is
confirmed quiet. Local metadata and bookmarks survive sign-out. Explicit sign-out
still clears the current queue and rejects new actions until cleanup completes.
An automatic transition to an unavailable service entry stops and offers sign-in
or another queue selection.

Account pages remain media-suspended. Authentication reads require the exact
current source and view. Profile changes revoke old window actions immediately,
drain accepted library writes and check output quiet before activation. Actual
file grants and shared profile ownership remain retained through readers, assets
and detached native items. An inactive profile containing local-library data
can remove only validated local-library metadata under the profile-cleanup
journal. Retained file grants and native items block cleanup; bookmark targets
and audio files are never removed.

## Verification

Deterministic tests use temporary metadata stores, fake file access and native
output drivers, and controlled Web acknowledgments. They cover migration, bounds,
service exclusions, revision conflicts, retained grants, stale events,
cancellation, preparation-time controls, output handoff, sign-out and paused
startup restoration. Controlled hosts remain empty and nonpersistent; these
checks do not play media or establish native decoding or file permissions.

Apple supports [local media in AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer).
Actual supported formats, chooser permissions, relaunch access, seek/end/repeat,
device interruptions, accessibility, long playback and service-to-local handoff
still require packaged-app verification on Intel/macOS 14 and Apple silicon.
