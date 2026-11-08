# Episode details

Episode Options includes Episode Details for the current selected service episode
in a confirmed signed-in account. Opening it makes an explicit metadata request;
it does not start playback, navigate the queue or update listening history. A
selected paused episode can be inspected before starting its playback occurrence.

The native sheet shows the service title, show, publication and duration labels
when supplied. Publication text remains text, not an inferred date. Description
text preserves line breaks and is selectable. It is displayed verbatim, without
HTML, Markdown, automatic links or external URL actions. Missing fields stay
unknown. The response does not replace queue metadata or become a local cache.

Source Timestamp References lists only explicit numeric `startTimeSeconds` values
from description watch endpoints targeting this same episode video. Source order
and labels are retained. Clock-like text alone, missing targets, other videos,
booleans, fractional values and out-of-range values cannot create references.
These are read-only positions, not inferred chapter titles or playback controls.
No seek action is provided by this feature.

## Request and ownership limits

Only the selected episode's documented primary header and first secondary
description shelf can supply details. Ambiguous tabs, multiple headers or
description shelves, and contradictory episode or video identities are rejected.
Related episode shelves cannot supply missing details.

The parser rejects responses above one MiB before decoding. It permits at most
1,024 description runs, 16 KiB per run, 64 KiB of description text and 128 timestamp
references. Header fields are bounded separately. Timestamp positions must be
whole seconds within zero to seven days. These bounds do not imply that an
unknown episode has a known duration.

Every read captures profile activation, account generation, queue revision,
selected entry, exact optional playback occurrence, canonical episode identity
and video identity. Each asynchronous controller boundary rechecks that owner;
the client separately checks its credential scope before and after the service
read. A changed selection, account, profile or closed sheet removes presentation
authority. Stale responses and arbitrary error text are not displayed.

One shared read slot prevents overlapping requests across profile controllers.
Cancel and close revoke pending result presentation immediately and request cancellation; the
slot remains occupied until the underlying fetch settles. Retry is explicit and
stays unavailable while the previous request is finishing. The HTTP transport
retains an admitted native task until its exact completion callback, including
after cancellation or size failure. Existing bounded read retries and network
time limits apply. There is no polling or automatic refresh.

## Source and acceptance

The pinned [ytmusicapi episode read](https://github.com/sigma67/ytmusicapi/blob/206d470bd857dde9e4c588170a23188037e03ad5/ytmusicapi/mixins/podcasts.py#L153)
establishes the `browse` request and selected header/secondary description paths.
Its [description parser](https://github.com/sigma67/ytmusicapi/blob/206d470bd857dde9e4c588170a23188037e03ad5/ytmusicapi/parsers/podcasts.py#L38)
identifies timestamp elements through numeric endpoint seconds. The reviewed
[current episode implementation](https://github.com/sigma67/ytmusicapi/blob/488dbf31d8f9173331c80375fdc2fb6de6d45f6d/ytmusicapi/mixins/podcasts.py#L153)
uses the same read route. Required MIT attribution remains in
[third-party notices](../THIRD_PARTY_NOTICES.md).

Google's [chapter guidance](https://support.google.com/youtube/answer/9884579)
describes titled manual chapters and automatic chapters. The reviewed Music
endpoint does not establish a separate chapter-title feed. This implementation
therefore exposes only the supplied timestamp references and does not infer
chapters from localized description text.

Synthetic parser, client and controller checks exercise bounds, exact source
paths, opaque text, timestamp ownership, credential changes, canceled reads and
stale profile/selection results. They do not establish live episode availability,
service schema coverage, native layout, keyboard or VoiceOver acceptance. No live
provider request or playback operation was performed for this implementation.
