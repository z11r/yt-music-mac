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

The commands are `play`, `pause`, `play video`, `set volume`, and `get player
info`. Volume uses a value from 0.0 to 1.0. Development bundles use the same
identifier with `.debug` appended.

`play video` requires an 11-character video ID. It looks up that exact song
through the native client and returns the queued ID. A successful command means
the playback request was accepted; check `get player info` to confirm audio has
started. The lookup times out, and a newer playback or account action can replace
it. A missing result never selects a different song.

Player info is JSON with playing/buffering flags, sign-in state, current video
ID, elapsed time, duration, volume, queue count, and a generic playback error
when present. It contains no account identity, credentials, or queue history.
These commands use the same player as the main window and compact controls.
