# Native playback commands

## Shortcuts

The app defines eight native Shortcuts actions that use the same session as its
windows and player. Building the app also extracts and validates their metadata
inside the app bundle. Add actions under YT Music for Mac in Shortcuts after
installing and opening the packaged app. Development bundles are separate apps.

| Action | Behavior |
| --- | --- |
| Resume Music | Resume the current selection. |
| Pause Music | Pause the existing player. |
| Next Song | Select the next entry in the app's queue. |
| Previous Song | Restart the song past three seconds, or select the previous entry. |
| Set Music Volume | Set app volume from 0 to 100 percent. |
| Play Song by Video ID | Resolve and request one exact 11-character video ID. |
| Open Music Link | Open an album, artist, or playlist; a song link requests that exact recording. |
| Search Music | Show the supplied catalog query without automatically playing a result. |

Playback actions require sign-in in the app. An action reports an error when
sign-in is needed; it does not open Account or accept credentials. Resume, song
navigation, exact playback, links, and search bring the app forward. Pause and
volume can run in the background. Transport adopts Apple's
[app-process audio intent](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)
behavior. No helper process creates another player or account store.

Actions run only when invoked. Listing actions does not search the catalog or
read account history. Invalid input and unknown links fail before dispatch.
Exact-song lookup never substitutes an unrelated result, and newer playback or
account actions can cancel it. The existing queue is kept if lookup fails. A
successful request does not establish that audio has started.

A cold invocation can report that the app is still restoring its account; run
the action again after startup finishes. Extracted metadata and isolated dispatch
tests do not establish installed Shortcuts discovery, Siri invocation, background
launch, playback, or macOS 14/Intel runtime support. Those checks remain required
on the installed app. Packaging explicitly requests compiler constant values for both the native
SwiftPM and Swift Build engines, then verifies all eight actions and phrases.
Missing or ambiguous compiler outputs fail packaging.

## AppleScript

The packaged app exposes AppleScript commands for playback. macOS may ask you
to allow the calling application to control YT Music for Mac. Sign in through
the app before starting a song; scripts cannot supply account credentials.

```applescript
tell application id "io.github.z11r.ytmusicmac"
    set volume 0.5
    play video "dQw4w9WgXcQ"
    get player info
end tell
```

Volume uses a value from 0.0 to 1.0. Development bundles use the same identifier
with `.debug` appended.

| Command | Behavior |
| --- | --- |
| `play`, `pause` | Resume or pause the current selection. |
| `play video` | Resolve and play one exact video ID. |
| `play videos` | Replace the queue with a list of video IDs and start its first entry. |
| `next track`, `previous track` | Use the app's queue navigation; Previous restarts a song past three seconds. |
| `seek to` | Seek to seconds within the selected song's known duration. |
| `set volume` | Set a value from 0.0 to 1.0. |
| `set repeat` | Accept `off`, `all`, or `one`. |
| `get player info` | Return the current player state as JSON. |
| `get playback snapshot` | Add the current entry UUID, occurrence generation, queue index, repeat, and shuffle state. |
| `check library` | Read a bounded library report containing counts and fixed status codes. |
| `check library navigation` | Read saved albums, artists, and listening history; at most three pages per surface within 15 seconds. |
| `check playlist edits` | Create, edit, and delete one new private test playlist using an exact video ID; this changes account data. |
| `retry playlist check cleanup` | Explicitly retry cleanup of the known new test playlist in this app session. |

`play videos` accepts 1–100 entries with at most 10 different video IDs. Repeated
IDs remain separate queue entries. Each distinct song is resolved once, and the
whole lookup has a 20-second deadline. A missing song leaves the current queue
unchanged. The command returns the number of queued entries.

`play video` requires an 11-character video ID. It looks up that exact song
through the native client and returns the queued ID. A successful command means
the playback request was accepted; check `get player info` to confirm audio has
started. The lookup times out, and a newer playback or account action can replace
it. A missing result never selects a different song.

Player info is JSON with playing/buffering flags, sign-in state, current video
ID, elapsed time, duration, volume, queue count, and a fixed playback error code
when present. It contains no account identity, credentials, or queue history.
These commands use the same player as the main window and compact controls.

Error codes distinguish blocked playback, unavailable media, a changed target,
missing controls, bridge failures, load timeouts, failed navigation, and a
terminated playback process. Page error text and URLs are never returned.

`check library` reads up to 25 pages per surface, with a 20-second deadline.
After checking the library and liked songs, it tries up to 50 discovered
playlists until one has pagination or a read fails. The report includes a
`playlist` surface for every attempted playlist, in order, including those that
fit on one page. `pageItemCounts` records the retained item count for each
page. The report states whether more pages remain, so it is not a
complete-library export. It includes no song titles,
playlist IDs, account identities, continuation tokens, or credentials. It does
not change playback, navigation, likes, or playlists.

Report schema version 2 adds `responseStructure` when a continuation uses an
unsupported response format. It lists paths built from a fixed allowlist of
container names, with object, array, element, and scalar counts. `/[]` groups
array entries. Direct children of `continuationContents` may also report up to
eight container names matching `[a-zA-Z]{1,64}Continuation`; their contents are
not inspected. Other unknown key names and all response values are omitted;
`unknownKeyCount` counts omitted keys. `truncated` marks reports that reached the
limit of 2,048 visited nodes, 12 nested levels, or 256 distinct paths. This field
helps diagnose pagination without exporting library content.

When an HTTP request is rejected, the report can include `httpStatusCode`.
The `requestRejected` status distinguishes these failures from a service outage.
Response bodies, headers, and request parameters are excluded.

The disposable playlist check is an explicit account mutation diagnostic. It
creates a private playlist, renames it, adds two copies of the supplied song,
reads their occurrence IDs, removes one exact occurrence, reads the result, and
deletes the playlist. Its report contains fixed statuses and counts. It never
edits a preexisting playlist or a song rating. Ordinary library editing remains
separately gated by operation.

The workload has a 15-second deadline and a separate five-second cleanup budget.
Read `passed`, `cleanupNeeded`, and `uncertainOutcome` before continuing. Keep
the app open if cleanup is pending: its verification client retains the known
new playlist and blocks another check. Cleanup never searches by title or
blindly replays an uncertain delete. A lost create response can leave an unknown
playlist that requires manual review in the service.
