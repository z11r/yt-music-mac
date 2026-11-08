# Save Queue as Playlist

**Queue Actions > Save Queue as Playlist** opens an immutable review of the
entire queue in its current order. Repeated song entries remain repeated.
Choose a title and confirm **Create Private Playlist** to begin. The current
queue and playback are kept.

Service playlist writing remains disabled in the normal build until the
corresponding signed-in edit checks are accepted. The review and local saved
queues remain available. Known uploads are rejected because their playlist
write path has not been verified.

The save creates an empty private playlist, then adds at most 100 songs per
request, up to the 10,000-song queue limit. The client reserves the app's
mutation lock for the operation. Fresh account checks and full playlist reads
verify the title, private status, edit permission, song order, and distinct
service occurrences before more songs are added. Every acknowledged batch is
read back before it is reported as confirmed.

**Stop After Current Request** waits for the current request's outcome and
records any known target or acknowledgement. It does not delete the created
playlist. Sign-out and account changes stop further writes and hide the
pending operation from other accounts.

A bounded, account-specific local journal is written before creation and
before every batch. Known target IDs and confirmed occurrences are recorded
with atomic replacement and disk synchronization. An exclusive file lock
prevents another process from using the same pending operation. The journal
contains reviewed song metadata and service occurrence identifiers, with no
credentials, artwork URLs, service parameters, playback position, or audio.
It is separate from the app's caches and is limited to 32 MiB.

On reopening, a pending record takes precedence over the current queue.
**Recheck Only** reads the known target without adding songs. **Continue
Reviewed Save** first requires an exact fresh match to the recorded occurrence
prefix. A batch with an uncertain outcome is never resent. If a read proves
the entire attempted batch is already present, that batch can be confirmed
and only the remaining songs can be added. An unchanged or partial prefix
stays pending; checking once does not prove that a delayed write cannot arrive.

If creation may have succeeded without a confirmed target ID, the app will
not create another automatically or search playlists by title. Review the
service library manually. **Forget Local Record** is an explicit local action:
the service playlist remains, and a later new save can create another playlist.
Completed saves also keep their local receipt until explicitly cleared.
Unsupported or corrupt records are preserved rather than replaced.

The service offers no transaction lock across different clients. Detected
changes to playlist details, permissions, order, or recorded occurrences stop
the save for manual review. Partial playlists are never deleted automatically.

The review, progress, and recovery messages follow the app's language. Counted
entries use singular and plural rules, including progress messages with a date.
Captured titles, artist names, playlist titles, and durable journal identifiers
remain unchanged. The queue counts entries so repeated recordings and podcast
episodes are represented without labeling every queued item as a song.
