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
These are source positions, not inferred chapter titles. Position labels preserve the full
admitted range: 604,800 seconds displays as `168:00:00`. They do not inherit the
ordinary playback clock's display cap.

## Go to a source reference

Go to Reference is an explicit action for the current playing service episode.
It is unavailable during pause, loading, buffering, advertisements or unknown
content. The target must be a member of the currently displayed details request;
changing the source request, selection, account, profile or playback occurrence
invalidates an older action. Only this source authority is captured by the native
row; an explicit click acquires the latest playback proof synchronously, so
ordinary progress does not stale the displayed source. A description label cannot
supply a position.

The action captures the exact acknowledged player, load, document, media and
command context. It requires an actual finite media duration and a position
strictly below that duration. The bridge checks those identities again at
execution, including the connected current media element, playing content and
absence of an advertisement. It assigns the position immediately; it never leaves
an ordinary pending seek to run after an ad or starts paused media.

Optional document-local monotonic and wall-clock samples must both have advanced
by more than zero and at most one second since the original playback snapshot.
Missing, frozen, backward or expired samples refuse only this action. This bounds
normal dispatch delays and clock anomalies; it does not establish guarantees
about malicious clocks or every operating system's sleep behavior.

A matching `seeked` event, unchanged media/intent and observed position are needed
for confirmation. A Promise receipt includes a bridge snapshot processed through
the normal playback event gate. The native receipt waits at most two seconds;
the bridge's confirmation listeners last at most 1.5 seconds. A timeout means the
change could not be confirmed, not that it did not occur. There is no automatic
retry, rollback, player recovery or optimistic clock/listening update. Closing the
sheet dismisses its receipt; it does not undo an already dispatched seek.

One process-wide action slot remains occupied until the actual JavaScript call
settles, including after a UI timeout, closed sheet or retired player. An exact
context refusal acknowledges the new command revision without seeking, so normal
playback messages can continue. If WebKit returns no acknowledgment, the action
reports an unconfirmed result and cannot restore older event authority or invent
success. A later ordinary command can establish fresh authority. Existing
SponsorBlock range actions retain their
separate validation and behavior.

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

Synthetic parser, client, controller and production-bridge checks exercise bounds, exact source
paths, opaque text, timestamp ownership, credential changes, canceled reads and
stale profile/selection results. Timestamp checks also cover exact source membership,
frozen/stale clocks, ads, command retargeting, held receipts, replay and late seek
confirmation. They do not establish live episode availability,
service schema coverage, native layout, keyboard or VoiceOver acceptance. No live
provider request or playback operation was performed for this implementation.
