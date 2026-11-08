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

Native audio/video switching is unavailable. A matching title does not establish
that two IDs are interchangeable recordings, or that their timelines align.
The pinned [Kaset video mode](https://github.com/sozercan/kaset/blob/6a20e60c5dfd552a22e84f36daeef53f94f1ee41/Sources/Kaset/Views/SingletonPlayerWebView%2BVideoMode.swift)
sets page state or activates a DOM control. Its
[track-credits parser](https://github.com/sozercan/kaset/blob/6a20e60c5dfd552a22e84f36daeef53f94f1ee41/Sources/Kaset/Services/API/Parsers/ParsingHelpers%2BTrackCredits.swift)
can extract an audio-side ID from a credits destination, but does not establish a
complete alternate-video pair or a seek-offset contract. Implementing a native
switch requires explicit alternate IDs, recording compatibility, position
mapping, entitlement behavior, and stale-request tests. Users can select an exact
video from search as a separate playback request.

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
