# Discovery shelf links

Explore already includes Featured, Charts, Moods & Genres and New Releases.
See All also follows supported links supplied by the first title run of a
carousel shelf, including new-album, new-video and mood/genre destinations.
A shelf can offer a link without preview items or a separate More button.

The existing See All button opens a native browse page. Opening that page does
not start playback, replace the queue, save music or change recommendation
preferences. It retains the service's title and order, uses the existing Load
More control when a continuation is supplied, and keeps failures available for
explicit retry. Availability can vary by account, region and service response;
an offered destination can still return an error or an unsupported format.

Only the service-provided action is used. The parser accepts the established
playlist, artist and discography page types, plus these exact untyped discovery
destinations:

- `FEmusic_new_releases_albums`
- `FEmusic_new_releases_videos`
- `FEmusic_moods_and_genres`

The app does not construct discovery IDs from labels or treat them as playlists.
Conflicting title/button destinations, different opaque parameters, multiple
action-bearing title runs, malformed values and explicit unknown page types
hide See All. Menu and related-item actions cannot supply a shelf destination.
The first title run is the only supported title-action path; a general search
through response text would risk opening a different destination.

Opaque parameters stay attached to the exact action and account scope that
provided them. A later account cannot reuse that action or its continuation.
Continuation requests retain their own cursor; they do not reuse the initial
title link's parameters. Category pages keep existing discovery deduplication;
playlist pages preserve repeated song occurrences. No new playback owner,
background request, local store, API key or provider is added.

## Mixes and source limits

YouTube's [personalized-mix announcement](https://blog.youtube/news-and-events/youtube-music-makes-discovery-more/)
describes mixes offered on Home. The current app can display service-provided
playlist cards and collection radio actions there. This change does not invent
a separate Mixes browse endpoint, generate recommendations locally or promise a
complete list of personalized mixes. A dedicated mixes destination needs its
own established service route and account coverage.

The pinned [ytmusicapi Explore implementation](https://github.com/sigma67/ytmusicapi/blob/206d470bd857dde9e4c588170a23188037e03ad5/ytmusicapi/mixins/explore.py#L217)
identifies discovery sections from the carousel title's first navigation endpoint
and supplies the three category IDs above. Its pinned
[navigation constants](https://github.com/sigma67/ytmusicapi/blob/206d470bd857dde9e4c588170a23188037e03ad5/ytmusicapi/navigation.py)
define that exact title path. Existing browse and continuation handling follows
the reviewed [Kaset client](https://github.com/sozercan/kaset/blob/6a20e60c5dfd552a22e84f36daeef53f94f1ee41/Sources/Kaset/Services/API/YTMusicClient.swift).
Required MIT attribution remains in [third-party notices](../THIRD_PARTY_NOTICES.md).
These source references establish request/response handling, not current live
availability for every offered page.

## Verification

`Scripts/with-xcode.sh swift test --jobs 1 --filter 'MusicDiscovery'` runs synthetic
parser and fake-client checks for title/button agreement, invalid and unrelated
actions, scoped parameters, retry, pagination, account changes, cancellation and
playlist occurrences. No provider request, authenticated session, playback,
native adapter or user storage is used by these checks.

Live signed-in and signed-out discovery coverage, native layout, keyboard and
VoiceOver checks remain pending. Some service responses omit destinations; an
omitted or unsupported action remains unavailable.
