# Video presentation

The Video menu opens the current web player in a separate native window or puts
that window in macOS fullscreen. Return to Main Window restores the embedded
player. The window displays the existing service page; the app does not extract
a media URL, copy the stream, or create a second playback engine.

Picture in Picture is available only when the current, verified content has a
visual video track and WebKit reports a supported presentation route. Requests
must match the queue occurrence, load, document, and media generation. A request
is confirmed only after the video reports the requested presentation state.
Unsupported, refused, stale, or timed-out requests do not restart playback or
advance the queue. Native controls show a separate presentation message.

The embedded anchor and the video window share one host. Hiding the embedded
panel does not hide a video window or an active Picture in Picture presentation.
These presentations keep the page available while visible. Closing the video
window returns the host; stopping or replacing the player closes out-of-window
media. When WebKit owns a fullscreen placeholder, host replacement waits for its
media-presentation cleanup callback before attaching the new view.

## Audio and video recordings

The Video menu's Other Recording action explicitly loads a paired recording
offered by YouTube Music for the current song. The review shows its supplied
title, artist and Song/Video classification. Add and Play from Start inserts
it next in the queue and selects that exact new entry. The original entry and
remaining queue are kept, along with shuffle and repeat settings. Loading or
closing a review does not start playback.

The [pinned watch implementation](https://github.com/sigma67/ytmusicapi/blob/206d470bd857dde9e4c588170a23188037e03ad5/ytmusicapi/mixins/watch.py)
documents an optional song/video counterpart. Its
[parser](https://github.com/sigma67/ytmusicapi/blob/206d470bd857dde9e4c588170a23188037e03ad5/ytmusicapi/parsers/watch.py#L6-L24)
reads both IDs from one playlist-panel wrapper. The native parser requires the
primary ID to match the requested current song and exactly one distinct
counterpart with the opposite ATV/OMV type. Missing, ambiguous, malformed and
unplayable pairs stay unavailable; search results and title similarity are
never used to choose an alternate.

Switching recordings while preserving playback position remains unavailable.
A supplied pair does not establish interchangeable timelines or equal durations. This action starts
a new occurrence at zero and does not change the web player's audio-only
preference. [Google's mode help](https://support.google.com/youtubemusic/answer/6313574?hl=en)
says music audio mode requires YouTube Music Premium or YouTube Premium, with
content and regional restrictions. A metadata offer grants no entitlement;
normal service playback and exact-ID checks still determine what can play.

The pinned [Kaset video mode](https://github.com/sozercan/kaset/blob/6a20e60c5dfd552a22e84f36daeef53f94f1ee41/Sources/Kaset/Views/SingletonPlayerWebView%2BVideoMode.swift)
sets page state or activates a DOM control. Its
[track-credits parser](https://github.com/sozercan/kaset/blob/6a20e60c5dfd552a22e84f36daeef53f94f1ee41/Sources/Kaset/Services/API/Parsers/ParsingHelpers%2BTrackCredits.swift)
can extract an audio-side ID from a credits destination, but does not establish a
complete alternate-video pair or a seek-offset contract. Preserving position
across a recording change still needs an authoritative position mapping and
mode-transition evidence.

The review is memory-only and expires after five minutes. Its profile activation,
account, credential scope, queue revision, entry and occurrence stay fixed.
Changes revoke it. A canceled read keeps its single process-wide slot until the
underlying work settles; profile shutdown drains accepted work. There is no
background counterpart polling, stream extraction, or saved pairing catalog.
The common transport's bounded transient-error retries still apply.

## WebKit boundaries and verification

Apple documents that [element fullscreen](https://developer.apple.com/documentation/webkit/wkpreferences/iselementfullscreenenabled)
moves a web view out of its original hierarchy; the
[fullscreen state](https://developer.apple.com/documentation/webkit/wkwebview/fullscreenstate-swift.property)
allows the host to respect WebKit's placeholder. Native window fullscreen and
element fullscreen are separate mechanisms. Picture in Picture uses the video's
[documented presentation modes](https://developer.apple.com/documentation/webkitjs/htmlvideoelement/1631913-webkitpresentationmode)
when supported, with a standard HTML video API fallback. Capability detection is
followed by transition confirmation; it does not promise that WebKit will grant
every request.

Deterministic tests use blank nonpersistent web views, injected window adapters,
and synthetic JavaScript media. They cover host transfer and replacement,
fullscreen cleanup ordering, unsupported and stale commands, request timeouts,
and unchanged transport and position. They do not enter native fullscreen,
start Picture in Picture, load an account, or stream media. macOS 14 and later,
Intel and Apple silicon, real service videos, closing animations, system PiP
controls, keyboard/VoiceOver access, and resource use still need runtime checks.

Counterpart fixtures additionally cover exact primary-ID binding, opposite types,
different titles/durations, invalid and unrelated pairs, account/profile/queue
revocation, held credentials and requests, shared admission after cancellation,
and queue preservation. Actual service counterpart availability, Premium and
restricted-account behavior, redirects and native review accessibility still
need runtime acceptance.
