# Playing collections

Play All loads the remaining pages of a playlist, album, or liked-song
collection, then replaces the queue and starts playback in collection order.
Shuffle All loads the same songs and shuffles every queue entry, including the
first. Turning shuffle off restores collection order. Repeated songs remain
separate queue entries.

Add All to Queue loads the entire collection before appending it. The existing
queue stays intact while pages load. Loading shows a song count and Cancel.
If a page fails, Try Again resumes from that page without adding the earlier
pages twice. A failed, cancelled, or superseded operation does not replace or
append a partial collection. Loading stops at 100 pages or 10,000 playable
songs and reports the limit instead of silently truncating the result.

Filtering applies to the pages already loaded. Loaded Matches offers Play
Loaded Matches and Add Loaded Matches to Queue. Selected Songs acts on the
selected visible rows. These actions are separate from Play All, Shuffle All,
and Add All to Queue, which include the full collection regardless of the
current filter. The collection heading says “songs loaded” while more pages
remain.

Changing the queue, using playback controls, navigating away, or changing
accounts cancels a pending collection operation. To start again, return to the
collection and choose the desired action. Signing in is required before
starting playback.
