# Build a queue from catalog searches

Choose **View → Build a Queue from Searches…**. Enter one to five phrases, one
per line, then choose Search Catalog. Each phrase reads one page of YouTube
Music song results. Nothing starts playing or changes the current queue during
the search.

The review alternates results from each phrase, preserves their service order
within each group, and removes repeated song identifiers. It offers at most
20 songs per phrase and 50 distinct songs overall. Each song shows the phrases
that returned it. Select songs, then add them to the current queue's end or
save a named local queue. Existing queue occurrences and playback stay intact;
adding an existing song creates a separate occurrence.
Edit Search Phrases returns to the draft and discards the current review.

Saved local queues require a confirmed sign-in and use the existing profile and
account storage. Saving does not create a service playlist or start playback.
The reviewed submission is consumed once before the local action. If a save
cannot be confirmed, check Saved Queues before preparing another submission.
The review retains its account, credential, startup and queue identities through
read and write admission. A save checks those identities again after obtaining
credentials, before entering the existing local store. Once admitted, a write
finishes only in its captured account; profile replacement waits for it.

## Coverage and privacy

Search phrases remain literal catalog queries. A phrase can describe an artist,
era, mood or genre, but results do not establish that every song meets those
criteria. This feature does not call a model or retrieve listening history.
Google receives the phrases only after Search Catalog is chosen, through the
same scoped native search client used elsewhere in the app. Draft phrases and
reviews are not persisted. Account/profile changes or closing the window clear
them. Queue edits invalidate the review while retaining its draft phrases.

Input is limited to 500 characters per phrase and 4,096 UTF-8 bytes overall.
The review inspects at most 200 result rows per phrase. Additional pages,
unavailable rows, unsupported content and truncation are labeled as partial
coverage. Only explicitly identified songs with usable metadata and a valid
playback identifier qualify; uploads, episodes and unknown music types are
excluded. Unknown metadata is not filled with invented names or identifiers.

Searches run sequentially, with one underlying builder read across profiles.
Cancellation revokes results immediately; a transport that has not settled
retains its slot. There is no scheduled refresh, background history, prefetch
or controller retry. A failed phrase prevents partial results from becoming a
review. Search again is an explicit new read of all phrases.
Profile replacement and shutdown also wait for an admitted catalog read to
settle, including a canceled request. Quiescing the session rejects new reads,
and a late reply cannot return a page under the previous owner.

## Reference behavior and remaining checks

[Spotify's Prompted Playlists](https://support.spotify.com/uk/article/prompted-playlists/)
document editable descriptions and refinements as a mobile Premium beta.
[Google's Ask Music guidance](https://support.google.com/youtubemusic/answer/17090260?hl=en)
describes generated mixes and playlists, with mobile-only availability at this
review. These references motivate an editable review; they do not provide an
API this native client can reuse. The catalog builder is a separate explicit
search workflow for the macOS 14/Intel target. It does not reproduce either
service's personal-history reasoning or generated explanations.

Deterministic tests cover input bounds, real-result ordering, exclusions,
deduplication, partial coverage, stale scopes, cancellation, once-only actions
and unchanged native playback. They use synthetic service responses and
isolated state. Signed-in catalog coverage, native selection/focus, French
layout, VoiceOver and saved-file outcomes remain runtime acceptance checks.
G51 remains partial; open-ended playlist generation requires its own evidence.
