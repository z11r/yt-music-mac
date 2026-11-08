# Uploaded music

The Uploads destination reads uploaded songs, albums, and artists from the
signed-in account. Browse Uploads switches categories; Search Uploads searches
the service's uploads scope. Catalog search remains a separate control.
Private album and artist cards open their uploaded songs with the same
account requirement. Pages load through the usual Load More control.

Uploaded songs and collections carry an Uploaded label. Track playback IDs,
private collection browse IDs, upload entity IDs, and local queue occurrence
IDs remain separate. Only a valid service video ID enters the playback queue.
The read paths neither upload files nor call upload deletion commands.
Rating and playlist mutation menus remain unavailable for uploaded tracks.

The optional `Track.origin` field preserves upload provenance through queue
storage and metadata updates. Older saved tracks decode with an unknown
origin. Account changes reject pending reads and continuation tokens; uploads
are never requested anonymously. Search selects the upload tab explicitly and
does not fall back to catalog or library tabs when that layout is missing.

Read paths and response fields follow
[ytmusicapi 1.12.3 at its pinned revision](https://github.com/sigma67/ytmusicapi/tree/206d470bd857dde9e4c588170a23188037e03ad5/ytmusicapi/mixins/uploads.py).
Synthetic tests cover request scope, paging, identity handling, account
changes, and queue restoration. Native uploaded-song playback and account
entitlements still need a controlled live check. These controls pass the
service video ID to the existing player; they do not establish an offline
playback path.

Google documents uploads as private to their owner and distinguishes their
search scope from the music catalog. Sharing a playlist does not give other
accounts access to its uploaded songs.
[Google's uploaded-music guidance](https://support.google.com/youtubemusic/answer/9716522?hl=en)
describes the service behavior; native upload management is tracked separately.
