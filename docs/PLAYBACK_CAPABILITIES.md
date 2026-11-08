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
| Extensions and filtering | Optional [SponsorBlock previews](SPONSORBLOCK.md) offer explicit guarded manual skips for eligible song sections, with default-off session consent. Real timing/provider acceptance remains pending. General extension hosting is not implemented; full WebKit extension hosting requires macOS 15.4 or later. |
| Language commands | Eight Shortcuts actions and exact Quick Commands use the shared session. Optional reviewed on-device interpretation targets eligible macOS 26 Apple silicon Macs; explicit catalog queue building also supports the macOS 14/Intel target. Installed invocation, model accuracy and native interaction remain runtime checks. |
| Appearance and feedback | System/light/dark appearance and optional native control accents are implemented with an Increase Contrast fallback. Custom palettes and haptics remain separate work; reactive visualization needs an actual audio source and a measured resource budget. |

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
need a newer OS than the playback baseline. The optional segment provider has a
separate session-only opt-in that explains the prefix lookup and connection IP.
On-device command interpretation has its own default-off consent and review step.
Neither feature starts work merely because the app launches.
