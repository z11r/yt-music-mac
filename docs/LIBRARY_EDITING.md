# Library editing

Remote edits are disabled by default while signed-in verification is pending.
Likes, dislikes, and playlist operations have independent capabilities in
`MusicLibraryEditCapabilities`; enabling one does not enable the others.

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
