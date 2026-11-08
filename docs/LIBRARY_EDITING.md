# Library editing

Remote edits are disabled by default while signed-in verification is pending.
Likes, dislikes, and playlist operations have independent capabilities in
`MusicLibraryEditCapabilities`; enabling one does not enable the others.
Description, privacy, playlist order, album saves, and artist subscriptions
each have a separate capability. Enabling basic playlist edits leaves these
additional operations disabled until their own signed-in checks pass.

When enabled, song rating actions are available in the player, track menus,
and queue menus. A song can be liked, disliked, neutral, or unknown. Like and
Dislike set an explicit rating; Remove Like or Remove Dislike clears a known
rating. Missing response data does not establish a neutral rating.

Ratings remain account-local. They change only after a confirmed response.
An uncertain write makes the cached rating unknown until a fresh service read
establishes it again. A response from an older read cannot overwrite a newer
confirmed or uncertain change. Signing out or switching accounts clears the
rating cache and rejects work from the previous account.

The service client's `MusicPage.ratings` preserves all three known states.
`likeStates` remains available for Boolean consumers, but a legacy false value
alone cannot distinguish neutral from disliked. Code that aggregates pages
must preserve `ratings` as well as `likeStates`.

Basic playlist forms cover creation, rename, deletion, and adding or removing
songs. Creation defaults to private. Existing-playlist edits check current
service permissions before submission. Duplicate songs retain separate
service occurrence identifiers, so removing one occurrence does not request
removal of every copy.

User-facing writes are serialized and carry the account scope captured at the
start of the operation. The client checks that scope again when taking the
credential snapshot and before and after the request. Responses must confirm
the requested operation; HTTP success alone does not establish success.
Writes are never automatically repeated after a timeout, lost connection,
server error, or uncertain result. Check the service before submitting again.

## Playlist details and library membership

When enabled, a playlist's actions menu offers description and visibility
forms only when its current response grants permission and supplies the
existing value. A known empty description can be cleared or replaced; a
missing description remains unknown. Custom cover upload is not implemented;
see the [supported paths and remaining requirements](PLAYLIST_COVERS.md).

Move Up and Move Down operate on one service occurrence, including when a
song appears more than once. They are available in the unfiltered service
order through the song menu and accessibility actions. A move across the
loaded-page boundary stays unavailable until its successor is loaded.
The client checks current edit permission and occurrence membership across
up to 100 pages and 10,000 occurrences before submission.

Album and artist pages offer Save Album or Follow Artist controls only when
their header establishes the current state and mutation target. Album saves
use the album's `OLAK` playlist target while navigation keeps its browse
identity. Artist follows use the subscription button's channel identifier,
which can differ from the artist page's browse identifier. Missing controls
and unrelated shelf items do not establish membership.

These additional operations require both an explicit success response and a
matching fresh service read before reporting success. Order readback checks
the exact occurrence and successor; album and artist readback checks the
same target and requested state. A failed or mismatched readback is uncertain
and never repeats the write.

## Disposable playlist verification

`YouTubeMusicClient.checkPlaylistEdits` is an explicit diagnostic for a
separately configured verification client with playlist edits enabled. It
creates one private playlist, renames it, adds the supplied song twice, reads
both occurrences, removes one occurrence, reads the remaining occurrence,
and deletes the playlist. It does not change song ratings or existing playlists.
The workload has a 15-second deadline and cleanup has a separate five-second
deadline. Cancellation still allows cleanup on the original account.

The result contains fixed status codes and occurrence counts. It omits song,
playlist, account, title, and occurrence identifiers. `passed` requires every
step and deletion to be confirmed. `cleanupNeeded` and `uncertainOutcome`
identify incomplete or uncertain work.

AppleScript diagnostics capture the current account generation before their
asynchronous work is scheduled. Profile quiescence rejects new or stale checks
and cleanup requests. A check admitted before the switch retains its original
service scope and result, including uncertain creation and cleanup status;
profile replacement waits for that work to settle. A failed profile switch
does not give an earlier queued command a new account generation. Read-only
library diagnostics follow the same native admission boundary.

Retain the verification client until cleanup is confirmed. It keeps the
created playlist identifier in memory and blocks another check while cleanup
is unresolved. An explicit `retryPlaylistEditCleanup` checks the original
account and reads current delete permission before one more deletion attempt.
It never searches by title. If creation did not return a confirmed identifier,
automatic cleanup is unavailable and the service needs manual inspection.
