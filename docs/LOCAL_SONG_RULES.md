# Local song rules

Local song rules create collections from song metadata captured on this Mac.
They use a dated snapshot of loaded songs for the confirmed account. They do
not search the complete YouTube Music library or change service playlists.

Open a music page and load the songs you want to include. In the sidebar,
choose **Edit Local Song Rules**, then **Capture All Loaded Songs**. Capturing
uses the page's loaded song order, including repeated entries. View sorting
and text filters do not change the snapshot. Every local song rule for that
account uses this shared snapshot; capturing again refreshes every rule's
source. No additional pages are fetched by this action.

The source label and capture date appear above the results. Notices identify
additional source pages, loading in progress, unavailable or unsupported
items, skipped rows, and the 5,000-row limit. Results always cover the captured
loaded songs, even when no additional pages were offered.

Name a rule, choose **All conditions** or **Any condition**, and add up to
12 conditions. Supported fields are title, artist, album, duration in seconds,
and explicit status. Text matching ignores case and accents. Genre, play
counts, ratings, and listening-history statistics are not rule fields.

Missing metadata stays unknown. For example, an unknown explicit status does
not satisfy **is not explicit**, and an unknown album does not satisfy
**does not contain**. Use **is unknown** or **is known** when that distinction
is part of the rule. The result footer counts song entries whose membership
cannot be decided from the captured metadata.

Choose **Save Rule** to update its results. **Play Matches**, **Add Matches to
Queue**, and the selected-song actions retain source order and repeated
entries. Listening uses the current account and requires the normal service
connection. Saving or opening rules does not start playback.

Rules and their snapshot remain local and separate from saved collection-card
filters, named queues, and YouTube Music playlists. Each account has a separate
versioned file, limited to 50 rules, 5,000 captured entries, and 8 MiB. Stored
song metadata contains no artwork URLs, service parameters, cookies, or audio.
Sign-out hides the account's rules and snapshot while retaining its files.
Use **Delete Rule** or **Clear Snapshot** to remove that local data explicitly.
Unsupported or corrupt files are kept rather than replaced by an edit.
