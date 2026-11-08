# Streaming metadata export

**Settings > Streaming Metadata Export** can write the current verified song
title and artist to a new JSON or TXT file you choose. It is off by default.
Choose a file, review the disclosure, and enable it for this listening session.
Another app, including a streaming app, can read the text and show it to its
audience. This exports metadata, not audio.

The target is remembered separately in the injected local profile's
preferences for the confirmed YouTube Music account. Switching accounts,
local profiles, or relaunching requires explicit consent again. A saved target
alone does not start export. Settings show only the current account's target.
The feature derives no new account identity and shares no service identifiers,
links, artwork, account details, cookies, tokens, or raw responses.

Only explicitly classified songs with supplied, bounded title and
artist text qualify. Known uploads, podcast episodes, unknown content types,
fallback artist labels, URLs, and control characters are excluded. The output
is limited to 4 KiB. Verified content progress can update it at most once every
five seconds. An active monotonic watchdog clears stale content after 15
seconds without verified progress. Off export schedules no recurring file
work or watchdog. Explicit target configuration and clearing can still write.

Pause, seek, buffering, ads, a playback change, sign-out, and normal shutdown
revoke pending publication immediately and clear verified owned output when
the file remains available. An old delayed write cannot pass the revoked
permission gate. Normal shutdown waits for the writer. File errors are shown;
changed or inaccessible files are kept, so stop displaying the target in your
stream if clearing fails.

## JSON readers

The JSON document has `version`, `state`, `updatedAt`, and `expiresAt` fields.
Only a `playing` document has `title` and `artist`. A `stopped` document omits
that text and expires immediately. Dates are UTC ISO 8601 values, and a playing
document's expiry is 15 seconds after its update.

Read defensively: ignore invalid, incomplete, future-dated, expired, or
unsupported documents. Display text only for version 1 with state `playing`
and an update-to-expiry interval no longer than 15 seconds. Writes happen in
place on an owned descriptor; a reader can briefly see an empty or partial
document. Treat that as absent metadata and retry on the reader's next normal
refresh. After a crash, JSON remains safe only when the reader honors expiry.

## TXT and OBS

TXT contains a single `Title — Artist` line, or is empty after a successful
clear. OBS documents **Text (Freetype2) > Read from file** for macOS in its
[text-source guide](https://obsproject.com/kb/text-sources). Choose the exported
TXT file as that source. OBS setup and actual refresh behavior still require
runtime verification.

TXT has no expiry mechanism. OBS can read a partial line during an update, and
a crash, forced quit, disk error, or changed target can leave old text visible.
Clear or hide the OBS source when needed. JSON consumers that enforce expiry
provide a stronger stale-content boundary.

## File ownership

Initial creation is exclusive and refuses existing files, symlinks, and
nonlocal volumes. The selected parent is canonicalized once, then reopened
component by component without following links. Private receipts record the
parent/file device and inode, format, revision, and expected content digest.
Later writes require the same regular, single-link, private file and matching
content. The writer pins the descriptor and never replaces the pathname, so a
foreign replacement is not overwritten. Detected edits or ownership changes
stop writes and clearing.

**Forget Saved Export Target** clears verified owned output if possible and
removes its private configuration. It keeps the file. Corrupt, future, or
foreign configuration is preserved until this explicit action. A crash between
a file update and its receipt update may require choosing a new target; the
app refuses an uncertain receipt rather than overwriting an unrecognized file.
Cache clearing does not delete export targets. Native dialogs, layout,
VoiceOver, local-profile switching, and OBS use still require runtime checks.
