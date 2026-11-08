# Optional non-music section previews

**Settings > Non-Music Sections** offers session-only SponsorBlock consent.
It starts off for every profile, account, and app launch. Enabling alone makes
no request. **Look Up Current Song** explicitly retrieves a preview; **Review
Non-Music Sections** in the player opens the same native controls.

Only explicit service song metadata, a valid video identifier, bounded supplied
title/artist, and recent confirmed native playback qualify. Known uploads,
episodes, unknown content, fallback metadata, ads, buffering, errors, and paused
or unconfirmed playback do not qualify. A legacy missing provenance field can
qualify only with explicit service song classification; an identifier alone
never establishes song kind.

The first integration supports SponsorBlock's `music_offtopic` category and
`skip` action only. Timings are community submissions and may be wrong. Ranges
with missing duration, duration differing by more than one second, negative
votes, duplicate identifiers, invalid bounds, or an endpoint at the recording's
end are excluded. Other categories and actions remain unsupported.

The preview lists retained original ranges. **Skip This Section** is available
only while confirmed playback is inside that range. It seeks to that range's
end through the existing native seek action. It does not automatically skip,
start playback, change the queue, or send provider feedback. Normal seeking
remains available.

At dispatch, the isolated player bridge checks the actual media, document,
occurrence, revision, duration, position, readiness, and ad state again. A late
ad, pause, loading state, seek, or media change refuses the optional action;
it never queues that section seek for later. Unconfirmed replies stay in the
optional preview's feedback and never trigger player recovery or a reload.

## Privacy and provider terms

Each explicit lookup sends the first four hexadecimal characters of the
video identifier's SHA-256 hash, the category, the YouTube service selector,
and a fixed client name. SponsorBlock and its caching proxy receive the
connection IP. The [documented prefix lookup](https://github.com/ajayyy/SponsorBlock/wiki/K-Anonymity)
reduces direct identifier disclosure; it does not guarantee anonymity.
The complete playback identifier, title, artist, artwork, account identity,
cookies, tokens, and credentials are excluded from requests.

The provider's [privacy policy](https://gist.github.com/ajayyy/aa9f8ded2b573d4f73a3ffa0ef74f796)
describes temporary hashed-IP user counting, proxy logging, and possible
connection-error logs. Review its [terms](https://gist.github.com/ajayyy/9e8100f069348e0bc062641f34d6af12)
and [data/API license](https://github.com/ajayyy/SponsorBlock/wiki/Database-and-API-License)
before enabling. SponsorBlock data is provided by Ajay Ramachandran and its
contributors under [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/),
including its noncommercial conditions unless separate permission applies.
The app's own code retains its MIT license. Source data timing values are
filtered for eligibility and displayed without editing their endpoints.

No consent, timings, response dataset, or lookup history is persisted. Only one
preview is retained in memory; its actions expire after five minutes and normal
playback updates clear an expired preview. Other videos returned in a hash
bucket are discarded. No user ID, submissions, votes, skip tracking, extension
installation, or provider account is created.

## Bounds and stale results

- One explicit read at a time and at least 30 seconds between admitted attempts.
  A canceled read retains its slot until the underlying transfer settles.
  Provider rate limits and `Retry-After` extend the local cooldown; nothing
  automatically retries or waits in a background loop.
- Exact HTTPS provider origin and read-only path/query whitelist, fixed headers,
  no shared cookies/credentials/cache, no redirects, ten-second request and
  twelve-second resource timeouts, and a 256 KiB streamed response limit.
- At most 128 returned video records and 64 segments per record, with two
  coordinates per range. The preview retains at most 64 matching ranges and
  requires the exact requested identifier. Duplicate matching video records
  fail closed. Unknown or inconsistent data grants no skip action.
- Native identity includes queue occurrence, load, document, media generation,
  command revision, duration, and account generation. A confirmed content sample
  must be no older than three seconds. Credentials and the full current scope
  are checked again after suspension and immediately before seeking.
- Pause, ads, buffering, recording/control changes, account detachment, profile
  quiescence, sign-out, and shutdown invalidate pending work and previews.
  Rollback or rebind leaves consent off. Existing scrobble/progress interruption
  handling and metadata-output gates remain in force for the native seek.

After admitted work settles, off state has no provider transport, lookup task,
polling timer, or autoskip watchdog. A visible active preview uses the existing
native playback clock.

## Source and acceptance

The [official API reference](https://wiki.sponsor.ajay.app/w/API_Docs),
[server hash route](https://github.com/ajayyy/SponsorBlockServer/blob/b691d945b5606ff37577277bb10e6a618bc72c70/src/routes/getSkipSegmentsByHash.ts),
[segment schema](https://github.com/ajayyy/SponsorBlockServer/blob/b691d945b5606ff37577277bb10e6a618bc72c70/src/types/segments.model.ts),
and [extension category configuration](https://github.com/ajayyy/SponsorBlock/blob/8cdda0b0b04de6f9cfe444031f035c1218c7da3b/config.json.example)
establish the request and category shapes. Server
[rate limiting](https://github.com/ajayyy/SponsorBlockServer/blob/b691d945b5606ff37577277bb10e6a618bc72c70/src/middleware/requestRateLimit.ts)
is deployment-configured; the app does not assume a fixed provider quota.
The pinned [Kaset extension guide](https://github.com/sozercan/kaset/blob/6a20e60c5dfd552a22e84f36daeef53f94f1ee41/docs/extensions.md)
describes installing a WebExtension, rather than this native implementation.
No SponsorBlock extension/server source, binaries, or artwork are imported.

Tests use synthetic metadata, fake providers, clocks, and local URL protocols.
Real provider availability, timing quality, native layout, VoiceOver, physical
resource use, and older-OS playback behavior require runtime acceptance.
