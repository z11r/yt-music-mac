# Reviewed local audio library

The local library controller and reusable native window content support explicit
file selection, review, saving, removal and reauthorization. They do not require a
YouTube account. The app session owns this controller; **View → Open Local Audio…**
opens its profile-bound window. Queue actions use the app's shared transport;
this controller does not create a player.

Choose Files accepts 1–100 files for one review. Each file must pass local-file,
identity and unprotected audio checks. Titles, artists and albums come from the
selected files and remain untranslated. English and French controls are included.
The private library holds at most 2,000 records.

Reviewing a file does not save its location or create a bookmark. Save Selected
Locations checks the selected files again before saving locations, metadata and
access information in the current local profile. The library stores references
to the selected files; it does not upload, copy, watch or scan audio. Canceling a
review leaves no new library records.

Locate or Reauthorize requires selecting the same volume and file identity. It
can replace access information for that record without changing queue references
or starting playback. A different file must be imported as a new record.
Identity matching compares filesystem volume and file identifiers, without
fingerprinting the recording; review its metadata before saving. The
controller never searches by filename, adopts a foreign library reference or
falls back to a service recording.

Remove from Local Library asks for confirmation and removes only the profile's
record. It never deletes the audio file. Pending access, prepared assets and
native item uses block record changes within this app process. An exclusive
record-change reservation also blocks new uses during reauthorization or
removal. This protection does not revoke another app instance's existing file
access. The private archive's OS lock and revision comparison separately protect
metadata writes across processes.

An unreadable, unsupported, future or foreign-profile archive remains intact and
disables writes. A changed revision requires another reload and review. If a
write's receipt is uncertain, the controller reads back the same profile's
archive when still current, reports the uncertainty and disables another
submission until explicit reload. Readback is not a claim of durable completion;
there is no automatic write retry.

Closing the window or changing its owner revokes pickers, drafts and future work.
Accepted operations retain their original profile resources until their actual
read or write settles. Profile replacement drains accepted library operations.
The same profile reuses its reference-use registry across reactivation while old
grants remain alive. A restored window waits for the selected profile to finish
loading before reading its library.

Add to Queue and Play Selection pass validated local tracks to an injected
transport callback with its captured queue target. Acceptance means the request
was accepted; it does not establish audible playback. The view cannot prepare an
engine or supply a raw playback URL. Portable service links, drag payloads,
provider exports and scripting do not receive file locations or bookmarks.

## Verification

`Scripts/with-xcode.sh swift test --jobs 1 --filter LocalAudioLibrary` runs the
controller and localization checks. They use memory stores, fake pickers, probes,
profile lifetimes and held receipts. They cover explicit confirmation, stale
actions, cancellation and draining, changed files, revision conflicts, uncertain
writes, in-use reservations, same-identity reauthorization and captured queue
callbacks. The localization check preserves placeholders and singular/plural
grammar while keeping file metadata opaque.

The native chooser, bookmarks, AVFoundation decoding, relaunch access and actual
playback remain packaged-app acceptance checks. No real selected files, dialogs,
bookmarks or assets are exercised by these controller tests. Long labels wrap,
the file lists scroll and metadata rows have bounded lines; actual VoiceOver,
French and right-to-left layout checks remain manual acceptance work.
