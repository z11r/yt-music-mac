# Playback capabilities

YT Music for Mac plays the service's web player through WebKit. Native controls
manage transport, volume, seeking, and queue identity. The app does not receive
decoded audio samples or own a native service-media decoder. A feature available
in another service client is not automatically available inside this player.

## Current boundaries

| Feature | Current capability and next step |
| --- | --- |
| Audio quality | The service selects the stream. Native quality selection and accurate format display need a verified observable path. A requested setting must remain separate from the actual stream. |
| Gapless | Queue transitions are implemented; playback without an audible gap is not established. Measure boundaries before claiming gapless. |
| Crossfade | Overlapping service playback and independent gain are not established. A two-player design also needs resource and account-behavior checks. |
| Normalization | The volume control changes gain. Track/album loudness normalization needs reliable loudness data and a supported processing path. |
| Equalizer | No per-app EQ is implemented. A process-tap prototype would require macOS 14.2 or later, explicit audio-capture permission, safe output restoration, and resource testing. |
| Offline downloads | Metadata, artwork, or browser cache do not establish a playable licensed download. The entitled service download flow, renewal, storage, and disconnected playback need verification inside WebKit. |
| Device routing | WebKit permits AirPlay. The native Audio Output picker still needs receiver and continuity checks. It does not establish Google Cast, service device handoff, or synchronized group listening. |
| Lossless or spatial audio | No source-format or spatial-content claim is established. Output sample rate, resampling, and EQ do not prove a lossless source. |
| Local files | Not implemented. A native file player is a possible separate source, requiring file access, persistent identity, queue migration, and engine-switching behavior. |
| Extensions and filtering | A general extension system and SponsorBlock integration are not implemented. Full WebKit extension hosting requires macOS 15.4 or later; native content rules are a narrower alternative. |
| Language commands | Eight structured Shortcuts actions use the shared session; installed discovery and invocation still need runtime checks. A typed-command layer or open-ended generation would be separate features. |
| Appearance and feedback | Native system appearance and accessibility preferences are the baseline. Static themes and event-driven haptics can be explored independently; reactive visualization needs an actual audio source and a measured resource budget. |

## Supported next steps

Keep macOS 14 and Intel playback complete while experimenting with newer APIs.
Start with local fixtures and one optional feature at a time. Measure the native
app and WebKit processes separately, including cleanup when a feature is disabled
or the player unloads. A successful build does not establish playback quality,
device support, offline entitlement, or low resource use.

Google documents Premium [quality choices](https://support.google.com/youtubemusic/answer/9076559?hl=en)
and [downloads](https://support.google.com/youtubemusic/answer/6313535?co=GENIE.Platform%3DDesktop&hl=en),
but those pages do not supply an embedded-player integration contract. WebKit
[storage policy](https://webkit.org/blog/14403/updates-to-storage-policy/) also
allows storage limits and eviction. Offline playback needs its own verification.

Apple provides [process taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
for an optional audio-processing experiment. Its
[WebKit extension APIs](https://developer.apple.com/documentation/macos-release-notes/macos-15_4-release-notes)
need a newer OS than the playback baseline. Third-party segment or model services
would require a separate opt-in that explains what leaves the device; none is
enabled in the app.
