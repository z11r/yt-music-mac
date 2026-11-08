# Podcasts

Podcasts opens the service's discovery page. Your Podcasts and Saved Episodes
read the signed-in account's library. Podcast show cards open paged episode
lists. Episodes use the existing playback owner and retain separate queue
occurrences; native podcast playback still needs a controlled live check.
No subscription or saved-episode mutation action is enabled.

Episode rows require a service episode browse identity or an explicit podcast
video type. `Track.contentKind` distinguishes episodes from songs, and
`EpisodeMetadata.identity` stores the provider and canonical episode browse
ID separately from the current playback video ID. Show references,
descriptions, publication text, and service progress remain optional.
Publication text is not interpreted as a date. Missing progress stays unknown;
service percentages are not converted into invented local resume times.

Older queue snapshots omit the new optional fields and continue to decode.
Metadata updates preserve known content identity and cannot replace another
episode merely because it shares a playback video ID. Personal library reads
require authentication; all continuation tokens remain bound to their
original account scope.

Discovery and response paths follow the pinned
[Kaset podcast parser](https://github.com/sozercan/kaset/blob/6a20e60c5dfd552a22e84f36daeef53f94f1ee41/Sources/Kaset/Services/API/Parsers/PodcastParser.swift)
and [ytmusicapi podcast methods](https://github.com/sigma67/ytmusicapi/blob/206d470bd857dde9e4c588170a23188037e03ad5/ytmusicapi/mixins/podcasts.py).
Synthetic tests cover browse routes, paging, metadata, account fences, and
queue compatibility. Local episode progress and episode playback controls are
separate from service history and subscription state.

## Local progress and playback controls

Confirmed episode playback records a local position for the selected account
and canonical episode identity. Ads, loading zeros, paused placeholders,
stale queue occurrences, and service progress percentages cannot create or
replace a bookmark. Automatic completion requires a confirmed episode-end event.
Separate [local episode status controls](LOCAL_EPISODE_STATUS.md) allow explicit
manual completion or clearing progress without claiming measured listening.
Selecting an episode waits for its local account data, then resumes a known
unfinished position. Resume and Start Episode Over are explicit player actions.

Progress and skip settings use a bounded, versioned local store with atomic
writes and account-specific files. The store retains at most 2,000 episodes
and one MiB per account. Malformed, newer, and mismatched account data remain
untouched. Signing out clears the active account's in-memory progress; its
local bookmarks remain available on a later confirmed sign-in to that account.
No listening history or progress is submitted to the service.

Episode controls skip backward or forward through the existing seek path.
Intervals are configurable and remain within 5–120 seconds. They are disabled
until the episode has a confirmed position and duration.

Playback-speed controls use a conditional adapter for the current service player.
The [YouTube player rate methods](https://developers.google.com/youtube/iframe_api_reference#Playback_rate)
describe available rates and warn that a setter call does not establish a change.
These embedded API methods do not establish universal support on the music site.
The app exposes only a list actually returned by the current service player,
with matching service and media-element rates. Missing methods, inconsistent
readback, advertisements, and unknown content do not grant a rate control.

The service adapter runs in the
[page JavaScript world](https://developer.apple.com/documentation/webkit/wkcontentworld)
because isolated content worlds do not share the page's JavaScript properties. A small per-video marker
carries only version, load/document/queue occurrence, media generation, known
content kind, readiness, and a rate-change counter. It contains no account,
credentials, episode bookmarks, progress positions, or local history. Both
JavaScript and native code validate the current scope and service video URL.
The adapter exposes only capability reads, episode rate changes, and a restricted
normal-rate reset; it is injected in the main frame only.

A speed change requires an observed rate-change event and exact service/media
readback of the requested supported value. It has its own revision and bounded
reply, independent of transport and video-presentation commands. Refused,
clamped, unsupported, timed-out, cancelled, and stale optional requests cannot
pause, seek, reload, restart, or advance playback. Native English and French
controls show pending or unavailable states and provide an explicit capability
refresh. Reads occur once per accepted media generation/rate counter and on
explicit refresh or rate changes, with no polling during ordinary song playback.

Only a confirmed rate change made by the app creates rate ownership. A rate
already selected by the page is not claimed. Page changes, inconsistent
readback, unknown content, account/session changes, and player replacement clear
ownership. On accepted known-song content, the app may attempt one reset to 1
only when the exact app-owned rate was inherited and 1 is offered by the service.
An uncertain or refused reset is not retried and is not reported as confirmed.
The temporary song-reset marker is then retired. Native transport, queue,
clock, and presentation ownership remain unchanged by optional rate work.

Synthetic JavaScript and native tests cover reported capabilities, scope and
revision fences, exact readback, ownership, ordinary-song inactivity,
conditional resets, cancellation, and optional failures. Runtime visibility of
the service methods, real episode speed changes, song transitions, and older-OS
behavior still require controlled live verification. No live rate or playback
operation was performed for this implementation.
