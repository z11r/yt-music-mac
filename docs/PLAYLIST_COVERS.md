# Custom playlist covers

Custom playlist cover upload is not implemented. Description, privacy, and
song-order edits retain their separate capability gates. Checking a playlist's
ordinary edit permission does not enable image upload.

## Available desktop workflow

Google's [desktop YouTube Music guidance](https://support.google.com/youtubemusic/answer/7205933?co=GENIE.Platform%3DDesktop&hl=en)
links to [custom playlist thumbnail instructions](https://support.google.com/youtube/answer/15400119?co=GENIE.Platform%3DDesktop&hl=en).
In the service's desktop interface, open the playlist, select Edit, choose
an image from the library, and pick the desired photo. This remains the
available workflow while native upload is pending.

## Established API and current gap

Reviewed November 8, 2026. Google's YouTube Data API documents a dedicated
[PlaylistImages resource](https://developers.google.com/youtube/data/reference/rest/v3/playlistImages)
with insert, update, list, and delete operations. Its
[insert method](https://developers.google.com/youtube/data/reference/rest/v3/playlistImages/insert)
supports square JPEG or PNG media. The
[list method](https://developers.google.com/youtube/data/reference/rest/v3/playlistImages/list)
can retrieve images by playlist ID or image ID. These operations require
OAuth authorization with one of the documented YouTube scopes.

The app's current service client uses a scoped browser session for requests
to `music.youtube.com`. It has no YouTube Data API OAuth authorization flow
or account-to-channel binding for those permissions. Google documents a
separate [desktop OAuth flow](https://developers.google.com/youtube/data/guides/authentication).
Browser sign-in and an existing playlist edit capability do not supply that
authorization.

The pinned [ytmusicapi playlist implementation](https://github.com/sigma67/ytmusicapi/blob/206d470bd857dde9e4c588170a23188037e03ad5/ytmusicapi/mixins/playlists.py)
has title, description, privacy, occurrence-order, and other playlist actions,
but no custom-cover upload method. The newer
[ytmusicapi source checked at this review](https://github.com/sigma67/ytmusicapi/blob/488dbf31d8f9173331c80375fdc2fb6de6d45f6d/ytmusicapi/mixins/playlists.py)
also lacks that method. The pinned
[Kaset service client](https://github.com/sozercan/kaset/blob/6a20e60c5dfd552a22e84f36daeef53f94f1ee41/Sources/Kaset/Services/API/YTMusicClient.swift)
provides playlist creation and song edits without establishing a custom-cover
upload or matching image readback path. Thumbnail parsing alone supplies no
write permission or upload contract.

The standard [Thumbnails.set method](https://developers.google.com/youtube/data/reference/rest/v3/thumbnails/set)
targets videos. The mutable fields in
[Playlists.update](https://developers.google.com/youtube/data/reference/rest/v3/playlists/update)
do not include an uploaded cover. Neither method establishes a substitute
for the dedicated image operation.

## Requirements before native implementation

- Establish a complete upload, replacement, and authoritative readback path
  for the app's supported authentication. A Data API integration requires
  registered application configuration, explicit scoped consent, secure token
  handling, and verified channel ownership within the current local profile.
- Read fresh target permission and current image identity before showing a
  native file picker on an explicit action. Validate bounded file bytes,
  decoded dimensions, actual JPEG/PNG format, and the reviewed square crop.
  Strip unnecessary embedded metadata before upload and bound the response.
- Keep an immutable reviewed image and target, serialize writes, and check
  account, profile, credential scope, and target revision before each request.
  Cancellation must revoke future submission without implying rollback of
  an already submitted request.
- Record an uncertain submission before it can become a duplicate write.
  Reconcile by the exact known playlist and image identities after fresh
  reads; a changed thumbnail URL or successful HTTP status alone cannot prove
  the requested image was applied. Never automatically repeat an uncertain
  upload or overwrite a later manual image change.
- Test malformed and oversized input, stale accounts and profiles, lost
  responses, concurrent image changes, cancellation, and readback mismatch
  with synthetic files and transports. Verify the resulting cover in both
  the service and the native view before enabling a separate production gate.

No browser-session image endpoint, native upload form, or new OAuth
permission is introduced by this feasibility review. Signed-in upload and
readback have not been exercised. G08 remains partial until this path and
its operation-specific acceptance checks are established.
