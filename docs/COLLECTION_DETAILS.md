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

Synthetic tests cover localized text, selected-header isolation, malformed and
oversized fields, client propagation, first-header preservation across pages,
duplicated recordings, unknown durations, overflow and English/French plurals.
Native layout, keyboard, VoiceOver and live metadata coverage remain acceptance
checks; source compilation and fixture tests do not establish them.
