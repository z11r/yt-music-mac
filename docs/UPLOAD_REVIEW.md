# Reviewing files for upload

Review Files for Upload is available in Settings → Uploads and beside the
account's upload browser. It prepares a local review; it does not transfer
music, modify local files, or add them to the playback queue.

Choose or drop between one and 100 files. The review shows file names, sizes
and extension matches, with findings for unsupported formats, unreadable or
empty files, symbolic links, folders and system-marked cloud placeholders.
It inspects file metadata only. It does not decode audio, read tags or artwork,
follow selected symbolic links, scan folders, retain bookmarks, or save the review to disk.
A matching extension cannot establish valid audio, DRM status, account
eligibility, duplicate content, or remaining service quota.

Only one metadata worker runs at a time. Cancel Review stops the local review
and rejects late results. A filesystem call already in progress may finish;
it cannot repopulate a canceled or replaced review. A changed account or
closed view clears the review. Cancel Review does not cancel an upload in
another app or browser.

Open YouTube Music in Browser passes only the fixed service landing URL to
the system. It sends no selected paths, file names, bytes, credentials or
account identifiers. The browser has its own sign-in; check its account before
choosing files there. The native review cannot observe browser transfer
progress, confirmation, cancellation or later library processing.

Google documents computer uploads through the website's profile menu or file
drop. It lists FLAC, M4A, MP3, OGG and WMA, permits personal accounts rather
than Brand Accounts, and describes browser progress and confirmation followed
by possible library delay. Its library ceiling is 100,000 songs; the native
review's 100-file bound is separate.
[Google upload guidance](https://support.google.com/youtubemusic/answer/9716522?hl=en)
is the source for these service restrictions.

## Native transfer boundaries

| Operation | Current behavior |
| --- | --- |
| Local file review | Bounded, metadata-only and cancelable |
| Service website | Explicit external handoff; separate sign-in |
| Native upload, transfer progress and cancellation | Unavailable; production writes remain disabled |
| Native service deletion, metadata editing and quota inspection | Unavailable |
| Native upload library | Existing read-only browsing/search; see [Uploaded music](UPLOADED_MUSIC.md) |

The pinned
[ytmusicapi upload implementation](https://github.com/sigma67/ytmusicapi/blob/206d470bd857dde9e4c588170a23188037e03ad5/ytmusicapi/mixins/uploads.py#L196)
establishes browser-authenticated start/finalize requests and a separate
entity-deletion path. It does not establish a native cancellation,
interruption-recovery or durable upload-to-library reconciliation flow for
this app. Its 300 MiB rejection is an implementation limit, not an official
service limit used by this review. No transfer or deletion code was imported.

Native transfers need separate evidence for account restrictions, safe session
URL/redirect handling, bounded streaming/progress, cancellation outcomes,
uncertain completion, retry/reconciliation and processing confirmation. A
similarly named Google upload protocol for another product does not establish
YouTube Music support. These gaps do not imply that native transfers are
impossible; they remain unverified and disabled.

Deterministic checks use injected file metadata, held readers, picker replies
and browser handlers. They cover count/URL limits, one-worker admission,
cancellation, stale contexts, findings, handoff privacy and translated count
grammar. They do not open real files, dialogs or browser sessions, or exercise
service uploads, persistent WebKit stores or Keychain. Native layout,
VoiceOver and actual file-provider behavior need isolated runtime checks.
