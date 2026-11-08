# Collection headers and loaded duration

Collection track lists show service-supplied subtitle and summary text when a
recognized header provides it. The service summary stays separate from counts
and durations computed from the rows loaded in the app. Localized numerals and
units are displayed verbatim; the app does not infer an authoritative total from
an English phrase or a formatted count. Missing header fields stay absent.

Description opens a bounded native popover with selectable text. It makes no
additional request. Account or destination changes dismiss it. Long metadata
cannot expand the track-list header indefinitely.

The app counts playable occurrences, including repeated recordings. An unfinished
page sequence, unavailable rows or unsupported content keeps the count labeled
as loaded. Filtering and sorting do not change these loaded statistics. Existing
notices still report excluded unavailable rows.

Loaded playable duration sums known positive finite durations. Unknown or zero
values remain unknown. A partial sum says “At least” and reports the number of
unknown durations; an entirely unknown duration has no invented time. Unloaded
pages and unavailable rows are excluded even when the service gives a larger
overall summary. Very large sums use a lower-bound label instead of wrapping or
turning into a short time.

Header metadata comes only from a recognized top-level header or the first
responsive header of a selected primary collection tab, or a sole tab with no
selection marker. Explicitly unselected, malformed and ambiguous tabs cannot
supply it. Related shelves and menus are excluded. Text is bounded, and malformed fields
do not erase other usable metadata. Pagination retains the initial header;
a continuation does not replace it or grant editing permission.

The [playlist header parser](https://github.com/sigma67/ytmusicapi/blob/488dbf31d8f9173331c80375fdc2fb6de6d45f6d/ytmusicapi/parsers/playlists.py)
establishes the service's subtitle and description shapes. This implementation
retains those displayed values instead of copying its numeral extraction.
No additional endpoint, provider or service write is introduced.

## Artist About text

Artist pages show About This Artist when the current response supplies a usable
description. The explicit native popover displays the complete supplied text,
including source and license credits. Supplied full source addresses appear as
selectable plain text; the app does not infer addresses from shortened labels,
open them, or request another provider. Provided by YouTube Music identifies the
delivery source, without claiming that YouTube wrote the biography.
Artist collection links and service-supplied artist shelf links are supported;
discography, category and upload destinations do not supply artist About.

The description comes from the direct description shelf in the selected primary
artist tab, or the immersive header when no description shelf is advertised.
Both single-column and two-column primary layouts are supported. Menus,
secondary content, related cards, unselected tabs, and ambiguous or malformed
renderers cannot supply it. An advertised malformed shelf never falls back to
header text. Unsupported extra attribution fields remain unavailable.

Descriptions are bounded to 16 KiB with at most eight supplied source addresses,
each at most 2 KiB. Oversize text or attribution is rejected as a whole instead
of being truncated. The popover has a fixed scrollable area. Its presentation
identity, profile, account, destination and metadata snapshot remain fixed;
changes hide the old content, and late disappearance cannot dismiss a newer
explicit presentation. It makes no request, changes no playback or service data,
and introduces no biography cache.

The pinned [artist implementation](https://github.com/sigma67/ytmusicapi/blob/206d470bd857dde9e4c588170a23188037e03ad5/ytmusicapi/mixins/browsing.py#L258-L290)
and [description-run helper](https://github.com/sigma67/ytmusicapi/blob/206d470bd857dde9e4c588170a23188037e03ad5/ytmusicapi/helpers.py)
establish these description and supplied-address fields. Google's
[artist profile guide](https://support.google.com/youtubemusic/answer/7237533?hl=en)
describes biographies appearing in YouTube Music. Native fixtures use synthetic
text and addresses, preserving the response structure without copying artist
biographies. Live biography coverage and native keyboard, VoiceOver, long-text
and right-to-left layout acceptance remain unperformed.

Synthetic tests cover localized text, selected-header isolation, malformed and
oversized fields, client propagation, first-header preservation across pages,
duplicated recordings, unknown durations, overflow and English/French plurals.
Native layout, keyboard, VoiceOver and live metadata coverage remain acceptance
checks; source compilation and fixture tests do not establish them.
