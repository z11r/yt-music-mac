# Local episode status

Episode menus and the player's Episode Options menu offer **Mark Completed
Locally** and **Clear Local Progress**. These actions change this app profile's
local progress for the confirmed account and canonical episode identity.
They do not change YouTube Music history, subscriptions, measured listening,
scrobbles or the playback queue. Audio continues at its current position.

Manual completion requires a known finite episode duration from that episode's
metadata or confirmed local progress. It preserves the last confirmed position.
If no position has been measured, the record stores zero with an explicit manual
completion source. Zero is not accepted as an ordinary listening bookmark.
Automatic completion still requires a confirmed episode-end event.

Clear Local Progress removes the local record. While that same occurrence keeps
playing, routine samples preserve the explicit completed or cleared state.
An explicit seek, Start Episode Over or a new playback occurrence resumes normal
tracking. Recovery of the same occurrence and a same-account session refresh
preserve the hold. Changing local status does not change episode speed or skip
settings. A new playback of a completed episode starts without a resume bookmark.

Actions are disabled while local progress is loading, when the account is not
confirmed, or when required metadata is unavailable. Rendered menu targets carry
the account, profile ownership, local status scope and playback occurrence;
actions from an older account, profile activation or occurrence are rejected.

## Local saving

The existing local-progress privacy setting still applies. With saving off,
status changes stay in memory and no retained file is read or edited. Unsaved
reset intent survives a later opt-in read, including an explicit Start Over made
before an old bookmark was loaded. If a confirmed seek follows the reset, its
actual new position wins over older stored data. Matching successful writes
acknowledge these changes; an older pending write cannot clear a newer intent.

Merges retain at most 2,000 records. Confirmed unsaved samples take precedence,
followed by explicit manual/reset state; remaining records use modification
time and canonical episode key for deterministic eviction. Each priority group
uses that same stable ordering when it exceeds the limit. Pending reset intents
are also bounded to 2,000. A full set produces a message asking to save before
retrying. A refused Start Over does not begin playback as though its clear succeeded.
Invalid or future stored data remains untouched, with current in-memory intent
retained until a valid read can succeed. The store remains limited to one MiB
per account and uses its existing permission checks and atomic writes.

## Sources and checks

Apple's [podcast episode settings](https://support.apple.com/guide/podcasts/pod48cadb787/mac)
provide episode-menu actions for marking played or unplayed. Google's
[history guidance](https://support.google.com/youtubemusic/answer/6313542)
describes service history as separate account activity. Those user-interface
patterns inform these explicitly local actions; they do not establish a native
service mutation path or authorize a history write.

Fixture tests cover manual metadata compatibility, known-duration constraints,
current-occurrence holds, recovery, seek and new-play behavior, stale targets,
privacy toggles, backward clocks, held reads/writes, continuation, rate/skip
preservation and bounded merges after failed loads. The new tests use in-memory
providers and synthetic dates. No service account, playback, real user data,
history mutation or listening submission is used. Native visual, keyboard and
VoiceOver checks remain runtime acceptance work.
