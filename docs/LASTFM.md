# Last.fm scrobbling

The Last.fm client and native Settings flow are implemented behind optional,
user-supplied registered-app credentials. Reporting remains off by default for
each confirmed YouTube Music profile. No application key or shared secret ships
with the app. Real registration, credentials, authorization, and submission
verification remain acceptance gates.

## Setup and authorization

For this development app, enter your registered Last.fm API key and shared secret
under “Registered app credentials,” then save them. The app stores them and any
subsequent user session in a separate Keychain service. Listening-data files
contain credential fingerprints and revisions, never credentials or signatures.
A secret distributed inside a desktop binary is recoverable, so release
credential distribution still needs an explicit project-owner decision.

Last.fm's [desktop authentication guide](https://www.last.fm/api/desktopauth)
requires an application key and shared secret. The app requests an unauthorized
token, then provides an explicit “Open Last.fm Approval” button. Approve the
registered app in the browser, return to Settings, and choose “Complete
Authorization.” That single explicit exchange obtains the user session. No
callback scheme, automatic browser opening, password collection, or polling is
used. Tokens expire after one hour and are consumed on successful session
creation.

The [authentication specification](https://www.last.fm/api/authspec) requires
signed `api_key`, `api_sig`, and session-key parameters. Signatures hash sorted
raw UTF-8 parameter names and values followed by the secret with MD5; `format`,
`callback`, and `api_sig` are excluded. This is a separate protocol from OAuth 2
bearer and refresh tokens. A ListenBrainz token cannot substitute for it.

Authorization still leaves scrobbling off. Enable it separately after reviewing
the metadata disclosure. Account changes, cancellation, credential changes, and
opting out fence stale results. Approval URLs are available only for the current
profile, app configuration, and unexpired token. A refused, not-yet-approved
exchange can be completed again explicitly. An ambiguous exchange is consumed
locally and requires a fresh authorization attempt.

## Listening and delivery

The [scrobbling guide](https://www.last.fm/api/scrobbling) requires a song longer
than thirty seconds and half its duration or four minutes of listening. The app
uses verified adjacent wall/media intervals. Seeks, pauses, ads, buffering,
recovery, stale occurrences, and unknown restored plays cannot fabricate elapsed
listening. Only identified catalog songs with known title and artist qualify;
uploads, podcasts, unknown content, artwork, YouTube IDs, and YouTube credentials
are excluded. Now Playing is not sent.

[`track.scrobble`](https://www.last.fm/api/show/track.scrobble) receives artist,
title, original UTC listening-start timestamp, duration, and optional album in a
signed POST. The response must confirm one accepted item and its timestamp;
ignored items remain visibly distinct from accepted listens. HTTP 200 alone is
insufficient. Selection provenance is optional: explicit manual selection maps to true, radio or
autoplay to false, and unknown origin is omitted. The native integration supplies
this value when available; it stays with the logical listen through restoration.

Last.fm has its own ledger, consent, queue-entry receipts, and outbox; enabling
ListenBrainz does not enable Last.fm or suppress its independent listens. Pause,
retry, and restoration retain logical identity. New plays and natural repeats
qualify only through their own listening time. Changing consent suppresses the
old partial play. Starting a replacement authorization blocks the old saved
session until a new exchange and credential save succeed.

Each attempt is saved before its POST. Ambiguous or interrupted attempts remain
uncertain across restart and are never selected by either send button. “Send
Unsent Listens” selects only never-attempted items. “Retry Explicitly Refused
Requests” allows an explicit retry after service errors 11 or 16, or after a new
session resolves error 9 for the same account. Other malformed-request refusals
are held. Rejected sessions stay blocked across restart; an old session's error
cannot invalidate a newer authorization.

## Bounds, removal, and verification

A profile file holds at most 100 pending items, 50 recent accepted/ignored
results, and 400 logical receipts within 512 KiB. Each run attempts at most five
items. A separate ephemeral HTTPS transport caps response data at 64 KiB and
request data at 16 KiB, with ten-second request and fifteen-second resource
timeouts. It permits only the two auth methods and scrobble endpoint, strips
unrelated headers, disables shared cookies/credentials/cache, and refuses
redirects.

“Discard Pending” affects local metadata. Disconnect removes that profile's local
configuration, credentials, session, pending items, and receipts. These actions
do not remove provider history or revoke an already granted provider permission.
Known late replies cannot recreate explicitly disconnected local data. Sign-out
hides and retains the original profile's files for its next confirmed session.

English and French Settings resources are included. Deterministic tests use fake
keys, signatures, transports, credential stores, clocks, and temporary files.
They cover explicit authorization steps, expiry, refused and ambiguous replies,
account/consent/session fences, independent providers, outbox recovery, encoding,
request isolation, and response limits.

Before calling the integration verified, complete real app registration and
credential-distribution decisions, then explicitly verify browser approval,
session storage, submission, provider-side acceptance, revocation, and disconnect
with an approved test account. No real browser authorization, Keychain operation,
Last.fm account access, or API submission has been performed here.
