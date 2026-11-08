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
replace a bookmark. Completion requires a confirmed episode-end event.
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

Playback-speed controls require an installed rate adapter, a verified episode
occurrence, and a supported-rate list from the current player. A rate change
is displayed only after that adapter confirms it; stale replies are ignored.
The current bridge has no rate adapter, so native speed controls remain hidden.
The [YouTube IFrame API rate methods](https://developers.google.com/youtube/iframe_api_reference#Playback_rate)
describe the embedded API's capabilities and do not establish support in this
app's music-player bridge. Bridge rate reporting, command readback, and resetting
music to its normal rate still need implementation and live verification.
