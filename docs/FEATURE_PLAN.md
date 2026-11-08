# Feature plan

Status reviewed November 8, 2026. This plan expands the [roadmap](ROADMAP.md)
with the remaining features, implementation order, and acceptance checks.
It describes proposed work, not a released feature set or delivery dates.

The target is a complete YouTube Music listening experience with native Mac
controls, predictable queues, and measured resource use. Core actions should
remain available on the macOS 14 target and both processor families. Features
that require newer systems must have an explicit availability boundary.

## Reference products

These are documented product capabilities, not results from comparative runtime
tests. Availability can differ by build, account, device, and region. The
priorities below are project recommendations derived from these references.

| Reference | Relevant documented capabilities | Planning implication |
| --- | --- | --- |
| [YouTube Music library](https://support.google.com/youtubemusic/answer/6313542?hl=en) and [desktop playlist editing](https://support.google.com/youtubemusic/answer/7205933?co=GENIE.Platform%3DDesktop&hl=en) | Library categories, history, ratings, playlist creation, ordering, descriptions, privacy, and covers | Finish the everyday service workflows and distinguish saved music from local organization. |
| [Kaset](https://github.com/sozercan/kaset#features) | Lyrics, radio-oriented queue features, discovery, podcasts, sharing, Mac integration, automation, and localization | Closest native-client reference; the current source feature list does not establish that every feature passes runtime checks. |
| [Pear Desktop](https://peardesktop.com/) | Optional integrations, scrobbling, lyrics providers, audio tools, video controls, and customization | Use its feature catalog to identify optional work; each integration needs its own resource and privacy checks. |
| [Apple Music MiniPlayer](https://support.apple.com/guide/music/use-music-miniplayer-mus71d7dcfce/1.6/mac/26) and [Smart Playlists](https://support.apple.com/en-is/guide/music/mus1712973f4/mac) | Compact controls with lyrics and queue access; rule-based library organization | Improve compact workflows and offer clearly labeled local organization. |
| Spotify [lyrics](https://support.spotify.com/us/article/lyrics/), [folders](https://support.spotify.com/us/article/playlist-folders/), [Connect](https://support.spotify.com/us/article/spotify-connect/), and [Jam](https://support.spotify.com/us/article/jam/) | Lyrics, playlist organization, device control, and shared listening | Separate everyday interface features from capabilities that depend on a service's device and social infrastructure. |

Advanced audio is a separate comparison. Apple documents
[AutoMix, Crossfade, Sound Check, lossless, and Dolby Atmos](https://support.apple.com/en-kz/guide/music/musdf855a1b/mac).
Spotify documents [desktop transitions](https://support.spotify.com/us/article/tracks-transitions/),
[normalization](https://support.spotify.com/us/article/volume-normalization/), and
[lossless playback](https://support.spotify.com/us/article/lossless-audio-quality/).
These establish useful comparison points; they do not establish equivalent
formats or controls in the YouTube Music playback path.

## Current implementation

| Area | Current state | Remaining work |
| --- | --- | --- |
| Playback | Native transport, radio, queue-end autoplay, sleep timer, seek, volume, shuffle, repeat, and recovery logic | Live transition, interruption, timer, and recovery checks on the combined build. |
| Queue | Duplicate-safe editing, undo, persistent restore, search, remaining duration, drag and drop, named saved queues, metadata/link exchange, recommendation previews, and reviewed playlist-save recovery | Native interaction checks; service playlist writes remain disabled pending live verification. |
| Browsing | Search filters/suggestions, library categories, history, podcasts, Explore categories/See All, service-offered chart countries, and metadata links | Live destination coverage, service-wide library search, and remaining metadata. |
| Pagination | A local release completed a non-liked playlist with 618 playable occurrences across seven pages | Repeat the live read with the combined build; verify failed-page recovery and displayed totals. |
| Collection playback | Play All, Shuffle All, and Add All load every page before changing the queue, with cancellation and retry | Live queue construction and navigation/accessibility checks. See [collection behavior](COLLECTIONS.md). |
| Library edits | Three-state ratings, operation-specific gates, basic playlist forms, and a bounded disposable-playlist diagnostic | Live confirmation before enabling each operation. See [editing boundaries](LIBRARY_EDITING.md). |
| Mac integration | Standard shortcuts, media keys, Now Playing, Dock, mini-player, menu bar, player windows, output picker, notifications, startup controls, links, and AppleScript | Device routing, notification delivery, installed login items, visual layout, and VoiceOver checks. |
| Lyrics | Service plain lyrics and validated timed lyrics, with attribution, stale-request fencing, and line seeking | Live recording/provider coverage and window/accessibility checks. |
| Local organization | Account-specific pins, folders, tags, saved loaded-library filters and rules over explicit captured-song snapshots | Runtime/layout checks; captured metadata does not cover the whole service library. |
| Advanced playback | Capability audit completed | Follow the specific playback-path and device proofs in [capability boundaries](PLAYBACK_CAPABILITIES.md). |

These implementations are on the feature development branch. Deterministic
checks establish local behavior; they do not replace signed-in, device,
accessibility, or older-system runtime validation. The table below retains the
remaining acceptance work for each package.

## Priority and status

P0 completes the daily listening path. P1 supplies the expected library and
desktop workflows. P2 adds useful optional features after the core release gates
pass. Research items need a feasibility result before an implementation promise.

“Partial” means some code exists but the complete action is unavailable.
“Implemented” means code is integrated on the feature branch, with runtime
acceptance still pending unless stated. “In progress” means implementation is
under way. “Missing” means a complete implementation is still absent.

## P0: complete daily listening

| ID | Feature | State | Acceptance check |
| --- | --- | --- | --- |
| G01 | Search filters, suggestions, and filtered-result paging | Implemented; live checks pending | Test typing, cancellation, empty/error states, keyboard focus, and signed-in results. |
| G02 | Standard playback shortcuts, output picker, track notifications, and mini-player on top | Implemented; device/accessibility checks pending | Verify keyboard focus and accessibility; integrate output, notification, and window-level controls. Verify actual WebKit audio routing, notification opt-in, and window levels. |
| G03 | Start Radio and optional queue-end autoplay | Implemented; live checks pending | Integrate; radio must respect manual queue edits, repeat modes, pause, account changes, stale responses, and failure retry. |
| G04 | Play, Shuffle, and Add Entire Collection across pages | Implemented; live queue check pending | Queue a collection larger than one page in service occurrence order; preserve duplicates. Show progress/cancel/retry and retain the previous queue on an incomplete replacement. Distinguish full-collection and filtered/selected actions. |
| G05 | Like and unlike from player, lists, and queue | Implemented; disabled pending live check | Confirm a live edit and restore its original state on an approved test item; verify state after reload. An uncertain response must not display confirmed success. |
| G06 | Dislike, remove dislike, and rating state | Implemented; disabled pending live check | Model liked/neutral/disliked separately; preserve state across views and verify actual service behavior. |
| G07 | Create, rename, delete, and add/remove playlist items | Implemented; disabled pending disposable check | Use a disposable test playlist for approved live checks. Verify occurrence-specific removal, duplicate policy, permissions, and uncertain outcomes before enabling. |

G05–G07 require an explicitly approved account-editing test. Read-only library
verification does not validate mutations. A lost write response requires
reconciliation before another submission; do not blindly retry it.

The first disposable private-playlist trial confirmed creation, rename, and two
added occurrences. Its readback and cleanup were unconfirmed. This does not pass
the G07 acceptance check; remote editing remains disabled while the issue is
open. Read-only checks on the combined universal build completed the 618-song
playlist across seven pages, the 44-item library across two pages, and 124 liked
songs across two pages. Saved albums, artists, and history returned readable
results; counts do not establish coverage of the entire listening history.

## P1: complete the library and native workflows

Library behavior is informed by the Google references above. Lyrics have a
documented precedent in [Spotify](https://support.spotify.com/us/article/lyrics/)
and [Kaset](https://github.com/sozercan/kaset#features), but provider availability
and the correct song version must be established separately.

| ID | Feature | State | Acceptance check |
| --- | --- | --- | --- |
| G08 | Playlist description/privacy editing, service reorder, and custom cover | Partial; edits implemented but disabled; cover authentication path researched | Implement each operation separately; retain service occurrence IDs and current edit permission. Confirm results after reload. See [cover prerequisites](PLAYLIST_COVERS.md). |
| G09 | Library tabs for Playlists, Songs, Albums, and Artists | Implemented; signed-in coverage pending | Add native destinations and paging; distinguish saved songs from liked songs and account uploads. |
| G10 | Save/unsave albums and follow/unfollow artists | Implemented; disabled pending live checks | Read authoritative state and confirm approved edits; an artist page alone does not establish subscription. |
| G11 | Recently played and listening history | Implemented; live checks pending | Separate service history from any local history; provide scope labels, account fences, and appropriate clearing controls. |
| G12 | Charts, moods/genres, new releases, mixes, and See All | Partial; categories, scoped See All and chart countries implemented | Add routes and pagination for each offered destination; retain service personalization without inventing recommendations. |
| G13 | Collection/library sorting, library search, and pinned playlist navigation | Implemented for loaded items; runtime checks pending | Offer supported title/artist/order choices; state whether search covers loaded items or the entire collection. Keep sort order separate from service order. |
| G14 | Rich track/album/artist navigation and metadata | Partial; links, explicit/unavailable indicators implemented | Add album and artist links, durations, available credits, explicit/unavailable indicators, and useful collection totals. Missing metadata must remain unknown. |
| G15 | Plain lyrics | Implemented; live checks pending | Prefer service-provided lyrics; handle instrumental/missing lyrics and stale requests. Show provider attribution where required. |
| G16 | Synchronized lyrics and optional line seeking | Partial; service timing and line seeking implemented | Require timing for the correct recording, seek with the native clock, reject stale results, and support readable static text and reduced motion. Translation/romanization needs an established provider path. |
| G17 | Copy link, native Share, and open supported music links | Implemented; runtime checks pending | Support songs/albums/artists/playlists; parse trusted URLs and app routes without losing the active queue on invalid input. |
| G18 | Recent searches and search-history controls | Implemented; session-local history | Distinguish local suggestions from service history; provide clearing and account isolation. |
| G19 | Queue search, remaining duration, drag-and-drop between views, and clearer manual/radio sections | Implemented; native interaction checks pending | Preserve occurrence IDs and selected order; unknown durations do not become zero. Keep user-added items distinct from recommendations. |
| G20 | Expanded Now Playing and compact-player lyrics/queue access | Implemented; window checks pending | Share one playback owner; preserve focus, window state, and playback when windows open or close. |
| G21 | Sleep timer, including end of current track | Implemented; runtime checks pending | Pause at the selected deadline, survive sleep/wake correctly, and cancel queue-end autoplay when the timer expires. |
| G22 | Launch at login and startup/window behavior settings | Partial; installed login-item setting implemented | Opt in through supported Mac controls; restore the intended windows without starting playback. |

The sleep timer is a project convenience recommendation, not a claim that every
desktop reference app includes one. Third-party lyrics lookup should remain
off until provider access, matching, attribution, caching, and the disclosure of
track metadata to that provider have been decided.

## P2: organization, integration, and content expansion

Local folders are inspired by [Spotify organization](https://support.spotify.com/us/article/playlist-folders/),
and local rules by [Apple Smart Playlists](https://support.apple.com/en-is/guide/music/mus1712973f4/mac).
Local structures must be labeled as such; they do not imply synchronization to
YouTube Music. [Google uploads](https://support.google.com/youtubemusic/answer/9716522?hl=en)
are a separate service library from files stored on the Mac.

| ID | Feature | State | Acceptance check |
| --- | --- | --- | --- |
| G23 | Local folders, pins, tags, and saved library filters | Implemented; runtime checks pending | Version and restore local organization; sign-out/account changes cannot mix private libraries. |
| G24 | Named saved queues, Save Queue as Playlist, and playlist-link import/export | Implemented; service writes disabled pending live checks | Preserve order and duplicates; export metadata/links only and import defensively. Service playlist saving depends on G07. |
| G25 | Rule-based local collections | Implemented for explicit loaded-song snapshots; runtime checks pending | Evaluate rules against a clearly stated, sufficiently loaded metadata set; expose incomplete results. |
| G26 | Native Shortcuts/Siri actions and configurable keyboard bindings | Implemented; installed invocation/settings checks pending | Add supported [App Intents](https://developer.apple.com/documentation/appintents); reuse native commands and honor locked/account/superseded states. Any global hotkeys are opt-in and conflict-aware. |
| G27 | Optional Spotlight library search | Implemented; default-off, installed checks pending | Opt-in indexing, bounded updates, and account-specific index deletion; older systems retain in-app search. |
| G28 | Localization, including long text and right-to-left layouts | Partial; English/French resources and plural rules integrated | Externalize strings; verify keyboard behavior, pluralization, layout, and non-English service results. |
| G29 | Cache limits, cache clearing, and read-only offline metadata | Implemented; storage/UI/resource checks pending | Show what is stored, bound disk/memory use, and clear caches without removing a valid session or saved queues. |
| G30 | Explicit privacy controls and multiple account/profile workflows | Implemented; live profile isolation and window checks pending | Distinguish local history from service listening history. Verify separate sign-ins, queues, caches, provider credentials and indexes; profile deletion remains unavailable. |
| G31 | Optional Last.fm/ListenBrainz scrobbling | Implemented; default-off, provider acceptance pending | Opt in; prevent duplicate reports across seek, pause, retry, and restore; store tokens securely and support disconnection. |
| G32 | Optional Discord presence and streaming metadata export | Implemented; default-off, native export and conditional Discord acceptance pending | Opt in; expose only selected public playback metadata, clear paused/stale presence, and keep background work bounded. |
| G33 | Desktop widget | Missing | Read shared snapshots without launching another playback engine; route actions through the app. |
| G34 | Browse/search/play uploaded music | Implemented; signed-in playback checks pending | Use the account's uploads scope; distinguish uploads from catalog results and verify permitted playback behavior. |
| G35 | Upload management | Source path researched; native transfer/management missing | Establish the supported upload path first; show transfer/cancellation state and verify account restrictions. |
| G36 | Podcasts, episode progress, speed, and skip intervals | Partial; browsing, local progress, skip and conditional speed controls implemented | Add episode identity and progress independently of music queues; verify subscriptions, paging, and resume. |
| G37 | Collaborative playlists | Missing | Respect collaborator permissions and concurrent edits; use the actual service workflow. This is separate from synchronized group playback. |
| G38 | Music-video toggle, fullscreen video, and picture in picture | Partial; shared native video window/fullscreen and conditional PiP implemented | Verify audio/video identity and position continuity; preserve single-player ownership and idle resource behavior. |
| G39 | Smart Shuffle or recommendation insertion | Implemented as explicit recommendation preview/insertion; runtime checks pending | Keep plain shuffle available; label inserted recommendations and preserve the user's explicit queue. |
| G40 | Service Recap and personalized summary access | Missing | Use actual available [Recap data or the official experience](https://support.google.com/youtubemusic/answer/11418178?hl=en-ZZ); verify desktop availability and do not fabricate listening statistics. |

Local song rules evaluate a dated capture of loaded songs, preserving missing
metadata and duplicate occurrences; see [local song rules](LOCAL_SONG_RULES.md).
[Queue playlist saving](SAVE_QUEUE_AS_PLAYLIST.md) journals each uncertain write
and does not replay it automatically. [Recommendation previews](QUEUE_RECOMMENDATIONS.md)
append only the songs the user accepts and preserve the existing queue.
[Chart country choices](CHARTS.md) use the service's offered tokens and label.
[Local profiles](LOCAL_PROFILES.md) have separate website stores and app data;
switching pauses playback and waits for accepted work before replacing its owner.
[Streaming export](STREAMING_METADATA_EXPORT.md) and [Discord presence](DISCORD_PRESENCE.md)
require separate, explicit consent for each listening session.

[ListenBrainz](LISTENBRAINZ.md) and [Last.fm](LASTFM.md) have independent consent,
credentials and delivery receipts. They require a provider connection; Last.fm
also requires registered application credentials. Neither provider has received
a live acceptance check on this combined build. [Video presentation](VIDEO_PRESENTATION.md)
shares one WebKit player; actual native animation/PiP behavior remains unverified,
and switching between corresponding audio/video recordings is still unavailable.

Scrobbling and external presence have precedents in
[Pear Desktop](https://peardesktop.com/). Synchronized social listening is a
larger service-dependent feature; [Spotify Jam](https://support.spotify.com/us/article/jam/)
is a reference for the experience, not an interface this client can reuse.

## Advanced playback and feasibility

The initial audit is complete. The remaining proofs below are required before
shipping these features; see [playback capabilities](PLAYBACK_CAPABILITIES.md).

| ID | Candidate | Required feasibility result |
| --- | --- | --- |
| G41 | Audio quality control and accurate quality display | Verify account-supported WebKit settings and observable formats; never label an unmeasured stream lossless or high resolution. [Google quality guidance](https://support.google.com/youtubemusic/answer/9076559?hl=en) describes the service's settings. |
| G42 | Gapless transitions | Measure gaps and prototype protected-player continuity without wrong-track events, duplicate endings, or unacceptable memory growth. |
| G43 | Crossfade/automatic mixing | Establish whether overlapping protected playback and independent gain are supported. Measure the extra player/process cost before deciding to ship. |
| G44 | Loudness normalization | Establish a supported service or per-app audio path; distinguish normalization from volume boosting or compression. |
| G45 | Per-app equalizer and presets | Prove a supported route for WebKit audio, safe gain, and acceptable latency/CPU. Do not silently process other applications' audio. |
| G46 | Offline music downloads | Verify the entitled service mechanism inside the embedded browser, storage renewal, and offline playback. [Google's download help](https://support.google.com/youtubemusic/answer/6313535?co=GENIE.Platform%3DDesktop&hl=en) does not prove this WebKit app can implement it. Cache metadata separately. |
| G47 | Casting and device handoff/group listening | Verify actual protocol/service support. [Google's computer casting instructions](https://support.google.com/youtubemusic/answer/9231765?co=GENIE.Platform%3DDesktop&hl=en) concern supported browsers/devices. An AirPlay picker is not Spotify Connect or a synchronized group-session implementation. |
| G48 | Lossless/spatial audio | Require actual service content and a supported playback/output path. Converting a compressed stream cannot create a lossless source. |
| G49 | Local-file playback | Decide whether this belongs in the product; it requires a separate file library, decoding/player path, permissions, and mixed-source queue design. |
| G50 | Web extensions, SponsorBlock, and content-filtering options | Review service compatibility, permissions, account behavior, performance, and supported OS APIs before adopting an extension system. |
| G51 | Natural-language commands and generated playlists | Partial: [typed Quick Commands](QUICK_COMMANDS.md) are implemented locally on the macOS 14/Intel target. Open-ended requests and generated playlists still need a supported implementation, privacy review and measurable cost. |
| G52 | Custom themes, visualizers, and haptics | Keep optional; validate contrast and reduced-motion behavior and measure idle/animation cost. |

## Delivery sequence

| Batch | Work | Dependencies | Exit condition |
| --- | --- | --- | --- |
| 1 | Integrated G01, G02, and G03; preserve artwork, pagination, recovery, and idle-unload changes | Current playback/queue baseline | Combined build and relevant tests pass; packaged search, controls, and radio receive live checks. |
| 2 | G04 whole-collection playback and live page-failure recovery | Batch 1 | A multi-page playlist plays/queues the intended complete occurrence set; cancel, retry, repeat, and account changes remain correct. |
| 3 | G05–G07 ratings and basic playlist editing | Read-only paging stable; approved mutation scenario | Changes are confirmed in the service; failures retain useful state and uncertain writes are reconciled. |
| 4 | G09, G11–G18 library, discovery, metadata, lyrics, sorting, and sharing; then G08/G10 | Batches 1–3; provider decision for lyrics | Normal daily tasks are available without opening the fallback web player. Each service action has its own evidence. |
| 5 | G19–G22 queue/Now Playing conveniences and the release gates below | Batches 1–4 | Keyboard and VoiceOver pass; long-session/resource/hardware results support a documented beta scope. |
| 6 | Select G23–G40 by demand; prototype G41–G52 individually | Stable beta baseline | Each optional feature has a clear benefit, supported path, isolated storage, and resource result before release. |

Start signing/update preparation while the feature batches proceed. A public
beta still requires the release gates; a broad optional backlog is not a reason
to delay a stable, clearly scoped release indefinitely.

## Release gates across all batches

- Run 100 actual playback transitions and a two-hour listening session; cover
  repeated songs, manual queue changes, retry, sleep/wake, and network loss.
- Test keyboard-only use, VoiceOver, Full Keyboard Access, focus during search,
  reduced motion/transparency, contrast, and window close/reopen behavior.
- Verify Bluetooth, built-in and external output changes. An output selector
  must control actual playback before being advertised as working routing.
- Measure visible/covered/paused states, scrolling, startup, and long-session
  growth across the app and attributed WebKit processes. Set budgets from
  repeated comparable measurements, including energy and latency where measured.
- Validate physical Intel, Apple silicon, macOS 14, and the supported newer OS
  range separately. Compilation alone does not establish runtime support.
- Complete Developer ID signing, notarization, installation, and recovery from
  a failed update. Add authenticated update delivery, release notes, and Check
  for Updates; [Sparkle documents this release path](https://sparkle-project.org/documentation/).
- Verify account data isolation, sign-out fences, supported service integration,
  and credential-free diagnostics. A subscription and an open-source client do
  not establish permission for every service integration.

Implementation can proceed locally while distribution credentials are
unavailable. Required signing membership/certificates and physical hardware
remain external prerequisites for their corresponding release claims.
