# Queue recommendation preview

**Queue Actions > Preview Recommendations** reads one page of the current
song's YouTube Music radio. It shows up to 20 eligible songs in service order.
Select the songs you want, then choose **Add Selected to Queue End**.
Opening the preview does not change the queue or start playback.

This is an explicit addition to the local queue. Plain shuffle stays available
and keeps its existing behavior. Every existing queue occurrence keeps its ID,
relative order, and source. Adding recommendations preserves the current
playback occurrence, pause state, repeat setting, and shuffle setting. New
entries have their own **Recommendations Added by You** section and badge.
That queue source is separate from a song's catalog or upload provenance.
The normal queue undo command can undo the addition.

The seed and candidates must be explicitly classified songs with valid
11-character playback IDs and supplied title/artist metadata. Known uploads,
podcast episodes, unknown content types, missing or fallback artist labels,
repeated candidates, and songs already anywhere in the queue are excluded.
Only the first 200 radio rows are inspected. The preview follows no
continuation, runs no periodic work, and stores no separate recommendation
history. Existing local queue persistence retains any entries you accept.

The preview is fixed when its read completes. Changing accounts, confirmed sessions,
playback intent, current occurrence, repeat mode, or queue entries invalidates
it. Acceptance checks the confirmed account again and appends only the selected
previewed songs, in their original service order, within the 10,000-entry queue
limit. Stale or repeated acceptance cannot append twice. Cancellation discards
the preview. A failed read offers an explicit retry for the same seed and
never changes the queue.

English and French copy identify recommendations and explain their scope.
The read uses the existing YouTube Music radio path; availability and results
depend on the service and account. No remote playlist or rating edit is made.
Native layout, keyboard selection, VoiceOver, and signed-in service behavior
still require runtime acceptance.

## Product references

Reviewed November 8, 2026. Spotify's current
[shuffle help](https://support.spotify.com/us/article/shuffle-play/) separates
plain shuffle from Smart Shuffle and identifies recommended content with a
badge. Its Smart Shuffle instructions specify mobile. This app's preview does
not implement Spotify Smart Shuffle or its recommendation algorithm.

YouTube's [getting-started guide](https://blog.youtube/news-and-events/get-started-youtube-music/)
describes personalized recommendations, custom radio stations, and radio
steering. Its [current help](https://support.google.com/youtubemusic/answer/6313542?hl=en)
explains that watched and liked content and artist subscriptions can influence
recommendations. The app presents actual songs returned by the service's
song-radio request; it does not infer personal tastes or promise a particular
radio-builder filter.
