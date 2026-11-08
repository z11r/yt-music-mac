# Last.fm scrobbling feasibility

Last.fm reporting is not implemented or enabled. No application API key or shared
secret is configured. ListenBrainz support does not establish a Last.fm
connection, authorize Last.fm writes, or complete this part of the feature plan.

## Authentication requirements

Last.fm's [desktop authentication guide](https://www.last.fm/api/desktopauth)
requires a registered application API key and shared secret. The documented flow
requests an application-specific token, opens Last.fm for user authorization,
and exchanges the authorized token through `auth.getSession` for a session key.
Tokens expire after sixty minutes and are consumed by the session exchange.
Session keys can be revoked from the user's Last.fm settings.

Authenticated calls carry `api_key`, `api_sig`, and `sk`. The signature is an MD5
hash of sorted parameter names and values followed by the shared secret. The
[authentication specification](https://www.last.fm/api/authspec) defines this
protocol; it does not specify an OAuth 2 bearer-token and refresh-token flow.
A ListenBrainz user token cannot substitute for these credentials.

Before implementation, the project owner must register the application, settle
its distribution and credential configuration, and review the applicable API
terms. A secret distributed inside a desktop app is recoverable; Keychain can
protect a user's local session but cannot make a distributed application secret
private. No credentials should be committed to this repository.

## Submission behavior to implement

The official [scrobbling guide](https://www.last.fm/api/scrobbling) requires a
track longer than thirty seconds and at least half its duration or four minutes
of listening. Now Playing is optional. Explicit errors 11 and 16 permit later
retry; error 9 requires reauthentication. Other malformed-request errors should
not be blindly repeated.

[`track.scrobble`](https://www.last.fm/api/show/track.scrobble) is a signed POST
with artist, title, and UTC listening-start timestamp. Album and duration are
optional. Its response distinguishes accepted and ignored items, including
metadata-filter outcomes. HTTP 200 alone cannot establish that a listen was
added. The `chosenByUser` field must reflect the actual selection source when
known; queue origin should supply that distinction.

The native implementation should reuse verified playback samples and the
listening ledger, with independent Last.fm consent, credentials, receipts, and
outbox. It should exclude uploads, podcasts, and unknown metadata by default;
start with new plays after opting in; and disclose the exact transmitted fields.
Neither provider's opt-in should enable the other.

## Remaining implementation and acceptance gates

1. Add a default-off, credential-aware configuration and explicit native Settings
   flow. Use the provider's browser authorization page only after user action;
   reject stale account, application, token, and authorization results.
2. Implement the exact signing and UTF-8 form encoding rules, a separate bounded
   HTTPS transport, and a Keychain adapter for the returned user session. Preserve
   cookie isolation and cancellation on account changes and opting out.
3. Save each attempt before its POST, classify accepted, ignored, authentication,
   explicit retryable, and uncertain outcomes, and keep the original timestamp.
   Hold lost or ambiguous replies until their replay safety is established;
   retryable response codes do not establish safety for every lost response.
4. Add synthetic signature fixtures, accepted/ignored and error fixtures,
   temporary-store recovery tests, account and consent races, and duplicate-play
   tests. Never log secrets, signed bodies, or raw listening metadata.
5. Separately verify registration, authorization, secure credential storage,
   submission, revocation, and disconnect with an explicitly approved test
   account before marking the provider complete.

No Last.fm authorization, token exchange, account access, credential write, or
submission has been performed for this investigation.
