# Spotify and YouTube Music comparison

Reviewed November 14, 2026 against YT Music for Mac feature checkpoint
`60794cc`. This is a product comparison and next-work plan. Competitor features
come from their published documentation, not a runtime comparison. Availability
varies by account, region, device and version. Desktop capabilities are the
primary comparison; mobile-only examples are identified below.

YT Music for Mac already implements most of the expected listening interface.
The largest practical gaps are disabled service edits, incomplete live
acceptance, and distribution. Device handoff, offline service music and advanced
audio are separate capabilities with unresolved integration requirements.

“Implemented” below means integrated source, with runtime checks still pending
unless the text says otherwise. It does not mean released. The current app has
no signed public download. The older native-player branch contains a smaller
feature set; this comparison uses the later feature-parity branch.

## What the app already has

- Playback, seek, volume, shuffle, repeat, radio, optional queue-end autoplay,
  recovery and a sleep timer.
- An editable queue with distinct duplicate occurrences, multi-selection,
  reorder, undo, search, duration estimates, named queues and paused restoration.
- Filtered catalog search, suggestions, separate service-library search,
  library categories, history, discovery, album/artist pages and full-collection
  Play All, Shuffle All and Add All across pages.
- Plain and timed service lyrics, guarded line seeking and optional Apple
  translation on macOS 15 or later. Translation still needs native acceptance.
- Media keys, Now Playing, Dock commands, menu bar controls, mini-player,
  playback windows, keyboard bindings, Shortcuts and AppleScript.
- Local folders, pins, tags, captured-song rules, isolated profiles, cache
  controls and reviewed local-file playback through AVFoundation.
- Partial podcast and video workflows; optional scrobbling, presence,
  Spotlight, metadata export, command review, accents and haptics.

See the [feature inventory](FEATURE_PLAN.md) for each implementation and its
acceptance checks. Optional integrations have individual opt-ins and remaining
provider, hardware or installed-app checks.

## Where the products differ

| Capability | Spotify | Official YouTube Music | YT Music for Mac |
| --- | --- | --- | --- |
| Discovery and radio | [Radio](https://support.spotify.com/us/article/spotify-radio/) generates related collections | [Personalized discovery](https://support.google.com/youtubemusic/answer/6313542?hl=en) uses service listening context | Search, service discovery, radio and reviewed recommendation insertion implemented; live coverage pending. No independent recommendation engine. |
| Ratings, saved music and playlist editing | [Desktop playlist creation, removal and reordering](https://support.spotify.com/us/article/create-playlists/) | [Desktop playlist editing](https://support.google.com/youtubemusic/answer/7205933?co=GENIE.Platform%3DDesktop&hl=en) | Ratings, playlist edits, album saves and artist follows have code but remain disabled. This is the most visible daily-use gap. |
| Playlist organization | [Folders appear across devices](https://support.spotify.com/us/article/playlist-folders/) | Service playlists and library categories | Local folders, tags, pins and rules implemented; this organization stays on the Mac and does not synchronize to YouTube Music. |
| Lyrics | [Lyrics for supported tracks and devices](https://support.spotify.com/us/article/lyrics/) | Service lyrics are consumed by this app where supplied | Plain/timed lyrics and optional translation implemented; actual coverage and translation acceptance pending. Language-aware romanization missing. |
| Personal audio | [Local-file playback](https://support.spotify.com/us/article/local-files/) | [Uploads from a computer](https://support.google.com/youtubemusic/answer/9716522?hl=en) create a service library | Local import/playback and uploaded-library browsing implemented; real decoding/access checks pending. Upload review opens the browser; native transfer management is missing. |
| Offline service music | [Premium desktop downloads](https://support.spotify.com/us/article/listen-offline/) | [Downloads](https://support.google.com/youtubemusic/answer/6313535?co=GENIE.Platform%3DDesktop&hl=en) are documented with mobile-oriented guidance | No verified service downloads. Artwork/metadata caches and local files are different features; embedded WebKit entitlement and renewal remain unproven. |
| Remote devices | [Connect controls another playback device](https://support.spotify.com/us/article/spotify-connect/) | [Cast and supported connected devices](https://support.google.com/youtubemusic/answer/9231765?co=GENIE.Platform%3DDesktop&hl=en) | Output picker exists; receiver routing needs testing. No implemented Cast or service handoff. |
| Shared listening | [Jam provides a shared queue and listening session](https://support.spotify.com/us/article/jam/) | Shared playlists use the service playlist workflow; this does not establish synchronized listening | Read-only contributor details implemented. Collaborative writes and synchronized group playback missing. |
| Transitions and loudness | [Crossfade/Automix](https://support.spotify.com/us/article/tracks-transitions/) and [normalization](https://support.spotify.com/us/article/volume-normalization/) | No equivalent embedded-player contract established in this audit | Gapless not proven; crossfade, normalization and EQ missing. Each requires a supported playback path and measurements. |
| Audio format control | [Lossless on supported Premium desktop versions](https://support.spotify.com/us/article/lossless-audio-quality/) | [Premium bitrate choices](https://support.google.com/youtubemusic/answer/9076559?hl=en) are documented for mobile | Native stream-quality controls and actual format reporting missing. No lossless or spatial-source claim. |
| Audio/video switching | Not used as the reference for this workflow | [Song/video switching](https://support.google.com/youtubemusic/answer/6313574?hl=en-sGB) documented for mobile | Shared video presentation and reviewed paired-recording playback implemented; continuous position-preserving switching missing. |
| Service summaries | Not assessed here | [Recap](https://support.google.com/youtubemusic/answer/11418178?hl=en) supplies service statistics/playlists | Native Recap missing; no fabricated service totals. |
| Mac-specific workflows | Native desktop app and keyboard workflows | [Installable Chrome web app](https://support.google.com/youtubemusic/answer/9231765?hl=en-asl) supports app launching and playback shortcuts | Native windows, menu bar player, Shortcuts, scripting and local organization are the product focus. Their presence does not establish a speed, memory or accessibility advantage. |

The main advantage to pursue is a dependable native Mac experience around the
YouTube Music account. Spotify has important device, social and audio features
that cannot be reproduced just by adding interface controls. YouTube Music's
official clients provide the reference for service behavior and account changes.

## Evidence and unfinished acceptance

At code checkpoint `267784d`, the recorded suite passed 1,533 deterministic
checks, with four live checks skipped. Intel/macOS 15 and Apple silicon/macOS 26
CI passed tests and packaging. A universal bundle and 100 synthetic rendered
queue changes passed locally. These are prior results, not new tests performed
for this comparison; see [compatibility](COMPATIBILITY.md).

Earlier live reads completed a 618-occurrence playlist across seven pages,
44 library collections and 124 liked songs. Failed-page recovery and agreement
with service totals still need live checks. A playlist-edit trial confirmed
some writes, but readback and cleanup were unconfirmed. The service-edit gates
remain closed. A two-hour listening run, 100 real transitions, full VoiceOver
acceptance and physical macOS 14/Intel runtime acceptance remain open.

No matched Spotify or official YouTube Music performance benchmark has been
completed. The older [Kaset measurements](PERFORMANCE.md) do not establish a
current advantage over either product. Optional TXT metadata export also has an
unresolved intermittent failure; it should remain off by default.

## Next work, in priority order

The following sequence updates the implementation-oriented batches in the
[feature plan](FEATURE_PLAN.md). It schedules acceptance and release work around
the code that now exists, without reopening completed feature implementations.
Each feature or integration fix should remain separately reviewable.

A bounded batch of [small features and integrations](SMALL_FEATURES.md) can
proceed alongside verification: finish Discord and scrobbling setup, then add
one local convenience. Larger optional capabilities retain the sequence below.

| Order | Deliverable and reason | Dependencies | Completion test |
| --- | --- | --- | --- |
| 1 | Verify one candidate build for daily listening. Highest value because the interface is already broad. | Exact packaged revision and signed-in test session | Search, library, multi-page Play All, radio, lyrics, local files and restore pass on that build; 100 actual transitions and two hours of listening show no wrong-track/double advances; retry, network loss and sleep/wake recover. Record failures and fix reproductions. |
| 2 | Enable ratings and basic playlist editing one operation at a time (G05–G10, G24). Removes the main reason to return to the official client. | Stable reads and explicitly authorized disposable service-edit scenario | Reconcile the earlier trial first. Confirm write, authoritative readback, duplicate occurrence handling, failure recovery and cleanup. Enable only the operations that pass; uncertain writes are not blindly replayed. |
| 3 | Complete native usability, accessibility and resource acceptance (M3, R3–R5). Supports the app's Mac focus. | Candidate from order 1; fixtures plus physical devices | Keyboard-only and VoiceOver cover search, queues, lyrics, sheets and windows; check English/French layout and reduced effects. Verify actual Bluetooth/external/AirPlay routing and installed Shortcuts/login behavior. Measure startup, time to audio, skips, CPU, footprint and long-session growth across app and WebKit; define budgets from repeated results. Test physical Intel/macOS 14 and Apple silicon. |
| 4 | Prepare a small signed beta and working update path (R6). Makes the app practical to install and maintain. | Signing identity, service-integration review, documented supported scope and orders 1–3 | Implement the updater controller, Check for Updates and authenticated signed feed. Verify Developer ID, notarization, fresh install, upgrade and failed-update recovery. Without credentials, finish local preparation and keep distribution pending. |
| 5 | Close selected remaining service gaps after beta scope is stable. | Feature-specific authority/provider evidence | Prioritize custom covers (G08), native upload lifecycle (G35), collaborative edits (G37), continuous audio/video switching (G38) and Recap access (G40) by actual demand. Each needs supported identity, error/recovery behavior and live acceptance before exposure. |
| 6 | Prototype one advanced capability at a time (G41–G48). | A supported service/device/audio path | Start with observable quality reporting and measured transition gaps. Downloads, Cast/handoff, crossfade, normalization and EQ proceed only after the individual feasibility proof. Record an unsupported result where appropriate instead of shipping a nonworking control. |

Orders 2 and 3 can proceed independently once order 1 provides a stable
candidate. Signing and updater preparation can start alongside them, but public
distribution waits for the release gates. This is an order of work, not a
calendar estimate; hardware, account permissions and credentials determine some
of the remaining effort.

A first beta should expose verified browsing, playback, queues, lyrics and Mac
controls, plus only the service edits that have passed. Keep unverified optional
integrations off and describe unfinished capabilities plainly. Widget packaging,
more themes, visualizers, open-ended playlist generation and romanization can
follow demonstrated demand; they do not need to delay that scoped beta.

## Immediate work package

Start with order 1 on a fixed universal build and a short, recorded daily-use
checklist. Follow it with the actual transition and long-session runs. Fix the
first reproduced playback or recovery failures before expanding scope. Keep
service writes gated until their separate approved test and reconciliation.
Update [testing](TESTING.md) and [compatibility](COMPATIBILITY.md) with the exact
revision and checks actually performed.
