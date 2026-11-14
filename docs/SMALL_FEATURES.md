# Small features and integrations

Priorities reviewed November 14, 2026 against feature checkpoint `60794cc`.
This plan covers conveniences that can be delivered alongside the reliability
and release work in the [product comparison](PRODUCT_COMPARISON.md).

Public requests in YTMDesktop and Pear Desktop provide specific examples of
user needs. They are qualitative signals from self-selected communities, not
a survey or a measured ranking of what all users want. Priorities below are
project recommendations based on those requests, the current source and the
remaining integration work. Existing code still needs runtime acceptance.

## Discord presence first

The app already has title/artist presence over local Discord IPC, per-session
consent, account isolation and clearing on pause or stale progress. Current
setup requires a user-registered application ID. It has no artwork, album,
progress display or song links, and actual registered-app display and clearing
have not been verified. See [current behavior](DISCORD_PRESENCE.md).

Users have explicitly requested [artwork](https://github.com/ytmdesktop/ytmdesktop/issues/284),
[album names](https://github.com/ytmdesktop/ytmdesktop/issues/607),
[artist/title display choices](https://github.com/ytmdesktop/ytmdesktop/issues/1618)
and [hiding idle activity](https://github.com/ytmdesktop/ytmdesktop/issues/190).
A newer [connection request](https://github.com/ytmdesktop/ytmdesktop/issues/1838)
describes the frustration of opening the player before Discord and having to
retry manually. An earlier [stuck-track report](https://github.com/ytmdesktop/ytmdesktop/issues/1372)
shows why update correctness matters as much as appearance.

Recommended delivery:

1. Register a project-owned Discord application and validate the existing local
   presence path with it. Supply its public application ID in release builds
   after acceptance; ordinary users should not need the developer portal.
   Keep sharing off until explicitly enabled and show connected, unavailable
   and sharing-paused states plainly.
2. Add optional album text, artwork and accurate progress, then a public
   Listen on YouTube Music link where supported. Test each field on actual
   Discord desktop builds. These fields expand the current title/artist-only
   disclosure, so the UI and consent must describe the selected data first.
3. Add a preview and a small set of display choices. Retain immediate local
   revocation, clearing and account boundaries. Offer Retry and evaluate a
   bounded reconnect triggered by Discord becoming available while consent
   remains valid; do not introduce permanent polling or restart sharing after
   consent ends.

Discord documents [timestamps, artwork and Rich Presence](https://docs.discord.com/developers/platform/rich-presence),
and [SET_ACTIVITY](https://docs.discord.com/developers/topics/rpc) accepts Listening
activity. Its [SDK client reference](https://discord.com/developers/docs/social-sdk/classdiscordpp_1_1Client.html)
describes desktop presence through the running client without connecting the
SDK client. This supports testing a streamlined integration; it does not prove
that every proposed field works through the existing adapter. Displaying a song
or opening its link does not implement synchronized Listen Along.

## Other worthwhile conveniences

Relative effort describes incremental engineering, not a time estimate.
Provider acceptance and installed-app checks remain separate work.

| Priority | Feature and user signal | Current app | Recommended increment | Relative effort |
| --- | --- | --- | --- | --- |
| First | Last.fm and ListenBrainz: [ListenBrainz request](https://github.com/pear-devs/pear-desktop/issues/1708), [Last.fm metadata complaint](https://github.com/ytmdesktop/ytmdesktop/issues/120) | Both implemented, off by default; live delivery pending. Last.fm requires user-supplied application credentials. | Finish provider acceptance and project-level credential decisions. Offer clear connect/disconnect, recent accepted/held status and accurate supplied metadata. Do not silently rewrite artist or album names. | Medium; registration dependency |
| First | Global shortcuts: [like/dislike feedback request](https://github.com/pear-devs/pear-desktop/issues/783), [volume hotkeys](https://github.com/pear-devs/pear-desktop/issues/1455) | Custom in-app playback bindings, media keys and Shortcuts exist; global bindings are missing. | Add opt-in global summon-player, play/pause, next and copy-link actions with conflict feedback. Ratings shortcuts wait for verified service edits and show confirmed outcomes. | Medium |
| First | Easier access to favorite actions: [custom player-button request](https://github.com/pear-devs/pear-desktop/issues/4753) | Player controls and share/link actions exist; player-button customization is missing. | Allow a small configurable set of player actions, such as copy link, lyrics, timer and Add to Playlist once enabled. Keep disabled capabilities unavailable and preserve keyboard/VoiceOver labels. | Small–medium |
| Next | Lyrics while working: [taskbar/overlay request](https://github.com/pear-devs/pear-desktop/issues/3149), [Mac companion request](https://github.com/pear-devs/pear-desktop/issues/4747) | Separate lyrics window and timed lyrics already exist; compact always-on-top lyric strip is missing. | Reuse loaded service lyrics in a resizable one/two-line window with pin, font size and static-text fallback. No second playback engine or new provider is needed for this presentation. | Medium |
| Next | Sleep timer: [requested intervals and end-of-song behavior](https://github.com/pear-devs/pear-desktop/issues/2484) | Countdown and end-of-track implemented. | Make presets and remaining time easy to find; verify cancellation and sleep/wake. After-N-tracks is a possible later addition, not current behavior. | Small for presentation; more for new timer modes |
| Next | Remember preferences: [shuffle/repeat restoration request](https://github.com/pear-devs/pear-desktop/issues/3004) | Queue/mode restoration, startup choices and mini-player on top exist. | Verify the complete relaunch workflow and expose relevant choices clearly. Restore paused; do not rebuild features that already exist. | Small for polish; runtime checks required |
| Next | Visual personalization: [Pear's album-color and ambient features](https://peardesktop.com/) | Appearance and per-profile control accents exist; artwork-derived ambient colors are missing. | Try an optional static artwork-derived tint using already-loaded art, with contrast checks and reduced-effects support. Defer continuously animated backgrounds. | Small–medium |
| Audience-specific | OBS Now Playing: [OBS text sources](https://obsproject.com/kb/text-sources) | JSON/TXT metadata export implemented; intermittent TXT failure remains open. | Reproduce and fix TXT ownership/lifecycle failure, then validate an actual macOS OBS text source before adding an overlay wizard or templates. | Small–medium if isolated; otherwise unknown |
| Audience-specific | Stream Deck, Raycast and Alfred control: existing scripting/Shortcuts provide a foundation | AppleScript and eight Shortcuts actions implemented; dedicated adapters not established. | First publish verified recipes using existing commands. A companion-app integration requires testing its contract; scripting alone does not establish compatibility. | Small for recipes; adapter-dependent |
| Later | Desktop widget and broader themes | Widget extension missing; only control accents implemented. | Keep a widget behind extension/shared-container/signing requirements. Test demand before building a theme system or visualizer. | Larger than the label suggests |

The Mac-specific shortcut path needs its own registration and conflict checks;
[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) is a useful
implementation reference, not a selected dependency. The current in-app
bindings must continue to preserve normal text editing.

## A bounded first batch

Finish the existing Discord setup/display path and one scrobbling provider's
acceptance first. Pair that with one fully local convenience: configurable
player actions or a global summon-player shortcut. Use real acceptance results
to choose the next batch, rather than adding every optional integration at once.

Each integration should show its actual connection or delivery state, explain
its shared data, stop work when off and retain native keyboard access. Keep
service-history privacy separate from hiding Discord or disabling scrobbling;
those local controls do not establish private listening on YouTube Music.

No Discord application, provider account or credential was created or connected
for this plan. Existing consent behavior is unchanged. Runtime verification,
resource measurements and live provider submissions remain pending.
