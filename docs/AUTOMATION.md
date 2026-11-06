# Native playback commands

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
ID, elapsed time, duration, volume, queue count, and a generic playback error
when present. It contains no account identity, credentials, or queue history.
These commands use the same player as the main window and compact controls.

`check library` reads up to two pages each from the library, liked songs, and one
discovered playlist, with a 20-second deadline. Its report states whether more
pages remain, so it is not a complete-library export. It includes no song titles,
playlist IDs, account identities, continuation tokens, or credentials. It does
not change playback, navigation, likes, or playlists.
