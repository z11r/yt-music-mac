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
