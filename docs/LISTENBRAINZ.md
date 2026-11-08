# ListenBrainz scrobbling

ListenBrainz reporting is optional and off by default for each confirmed YouTube
Music profile. Settings provides token verification, a separate enable switch,
connection checks, pending-listen counts, and local-data removal. Verifying a
token does not enable reporting. The token is stored in Keychain; listening
metadata and delivery receipts use a separate local file for that profile.

Enabling applies to new song plays. The app sends title, artist, optional album,
measured duration, the first confirmed listening timestamp, and app/service names
to the connected ListenBrainz account. Listens may appear on its public profile.
Only explicitly identified catalog songs qualify. Uploads, podcasts, unknown
content, unknown artists, artwork, YouTube identifiers, cookies, and YouTube
credentials are excluded. Now Playing notifications are not implemented.

## Listening and delivery

A song must exceed 30 seconds. The app counts adjacent confirmed playback
intervals and requires half the duration or four minutes of actual listening.
Seeks, ads, pauses, buffering, stale playback occurrences, and missing progress
break continuity. This follows the threshold in the
[ListenBrainz submission API](https://listenbrainz.readthedocs.io/en/latest/users/api/core.html#post--1-submit-listens).
The minimum duration and conservative content exclusions are app policy.

A logical play retains its identity through pause, playback recovery, and queue
restoration. An unknown restored play cannot invent a historical listen. A new
selection or natural repeat can qualify again after its own listening time.
Turning reporting off suppresses the current partial play. Turning it back on
starts with subsequent new plays.

Each qualifying listen is saved before sending. The request uses the documented
[`import` JSON format for saved listens](https://listenbrainz.readthedocs.io/en/latest/users/json.html#submission-json),
with one listen per request. Confirmation requires HTTP 200 and a recognized
success body. A rejected response pauses delivery. A timeout, cancellation, lost
response, or ambiguous reply stays uncertain; restarting also holds any saved
in-flight attempt. Attempted items are never automatically retried. The API
documentation does not establish an idempotency key that would make such retries
safe.

“Check Connection and Send Unsent” only selects items that have never been
attempted. “Discard Pending” removes local pending metadata and retains the
current play's submission receipt. Disconnect removes that profile's local
settings, receipts, pending metadata, and Keychain token. These controls do not
delete provider history or retract requests already received by the provider.

## Bounds and verification

The outbox holds at most 100 pending items and 50 recent confirmations. The ledger
keeps at most 400 queue-entry receipts. A profile file is limited to 512 KiB;
malformed, oversized, and newer-format files are retained without being replaced.
Each delivery run attempts at most five unsent items. Requests have a ten-second
request timeout and fifteen-second resource timeout, with a 64 KiB response cap.

Networking uses a separate ephemeral HTTPS session with an exact provider origin,
explicit provider authorization, no shared cookies, credentials, cache, or
redirects. Account changes and opting out close the submission gate immediately.
Delayed acknowledgments can update only the original pending item and cannot
recreate explicitly deleted local data.

Deterministic tests use fake clocks, temporary files, an injected credential
store, and fake transports. They cover thresholds, seeks, recovery, consent
races, account changes, uncertain delivery, file bounds, request isolation, and
response limits. Live token storage and provider delivery have not been verified.

Native settings, delivery messages, and local storage errors follow the app's
language. Pending counts select singular or plural independently for unsent,
uncertain, and rejected listens. Provider usernames, listening metadata, API
field names, and persisted delivery states retain their original values.
