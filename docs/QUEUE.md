# Queue behavior

The queue preserves separate occurrences of repeated songs. Filtering searches
loaded song, artist, and album text without changing playback order. Remaining
duration excludes completed entries and labels unknown durations explicitly.

Adjacent entries are grouped by how they entered the queue: Added by You,
Radio, or Autoplay. Groups retain playback order, including when a manual
insertion separates recommended entries. Older saved entries whose source was
not recorded appear under Queue. Source metadata survives move, undo, shuffle,
and named-queue restore. It does not change recording or occurrence identity.

Drag reorder operates within a displayed source group. Move Up and Move Down
can move a selection across groups. Filtering disables movement; clearing the
filter restores it. Queue changes do not reorder a service playlist.

Saved Queues stores named snapshots for the confirmed account on this Mac.
Opening a saved queue replaces the current queue without autoplay. Metadata
import/export includes song information and canonical service links; it does
not include credentials, account identity, audio, or playback positions.
