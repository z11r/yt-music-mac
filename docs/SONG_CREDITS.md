# Song Credits

Song menus and the player's Song Information menu offer Song Credits when
YouTube Music supplies a credits destination for that exact recording. The
menu-bar action uses the current recording. Opening the native window makes
one detail request; it does not start or reload playback. Cancel stops the
visible request, and Try Again explicitly requests the same recording.

The window preserves the returned section order, titles, names, separators and
metadata attribution. Section titles can be localized or unfamiliar. They do
not become fixed role categories or guessed links to people. Missing credits
remain unavailable, and an unsupported response is shown as a failed request.

Credits are fetched only when opened. Closing the window, changing accounts,
or shutting down clears its selection and cancels pending work. Requests and
responses are fenced to the captured account generation and service session.
No separate player, polling timer or persistent credits cache is added.

The optional credits reference survives queue restoration, metadata refresh
and internal song drags. Older queue files remain readable. Portable queue
exchange does not require or export the reference. Uploads and podcast
episodes do not offer this song-only action.

## Service support

Google documents Song Credits as metadata provided by labels or distributors;
availability varies by recording. See [View song credits in YouTube Music](https://support.google.com/youtubemusic/answer/13420518).

The read path follows pinned ytmusicapi
[`get_song_credits`](https://github.com/sigma67/ytmusicapi/blob/206d470bd857dde9e4c588170a23188037e03ad5/ytmusicapi/mixins/browsing.py#L586),
its [dialog navigation path](https://github.com/sigma67/ytmusicapi/blob/206d470bd857dde9e4c588170a23188037e03ad5/ytmusicapi/navigation.py#L112),
and the song's [own menu reference](https://github.com/sigma67/ytmusicapi/blob/206d470bd857dde9e4c588170a23188037e03ad5/ytmusicapi/parsers/playlists.py#L153).
The application never constructs an `MPTC` destination from a video ID. Multiple
different menu references, unsupported scoped parameters, malformed identifiers
and oversized content are rejected. Public credits can use the existing
anonymous session; an account is not required solely to open them.

Credits parsing accepts at most 1 MiB, 64 sections, 1,024 runs per text field and
100,000 UTF-8 bytes of credit text. The request has a cancellable 15-second
deadline within the existing bounded service transport. Deterministic tests
cover schema failures, localized and unfamiliar sections, attribution,
cancellation, stale selections and account/session changes. Live availability,
native window behavior and accessibility remain runtime acceptance checks.
