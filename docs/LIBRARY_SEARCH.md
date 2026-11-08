# Search your service library

Choose Your Library from the toolbar's search source menu, enter a query, and
press Return. This requires a confirmed sign-in. The search sends your phrase
to YouTube Music for the selected category: Songs, Videos, Albums, Artists,
Playlists, Podcasts or Episodes. It searches the service library rather than
only the rows already loaded on this Mac. Uploads retain their separate search.

Results load one page at a time. Load More preserves the original query,
category and account. A failed page keeps its continuation for an explicit retry;
changing the query, category, account or local profile rejects stale replies.
Searches never start playback, change the queue or edit the service library.

Catalog search remains separate. Existing search commands, Shortcuts and public
search links still use the catalog. The collection's Filter loaded songs field
and local library filters continue to cover only their loaded rows. Library
typing requests no service suggestions and displays no catalog suggestions.
Recent searches retain their source and category only in this app session;
account/profile changes clear them and their navigation history.

## Response coverage

Library requests follow the pinned
[ytmusicapi search parameters](https://github.com/sigma67/ytmusicapi/blob/206d470bd857dde9e4c588170a23188037e03ad5/ytmusicapi/parsers/search.py#L212)
and [filtered continuation flow](https://github.com/sigma67/ytmusicapi/blob/206d470bd857dde9e4c588170a23188037e03ad5/ytmusicapi/mixins/search.py#L265).
Mixed All and Profiles are not offered. Only a recognized filtered result tab
or direct search container is accepted; ambiguous catalog/library/upload tabs
and unsupported continuation formats produce an error rather than a fallback.
Service titles remain verbatim. Filters never invent song kinds, upload identity
or catalog provenance for rows whose metadata does not establish them.

Each response is bounded to 1,000 rows, with at most 100 continuation requests
and 10,000 distinct results. Repeated continuation tokens are rejected. These
limits and unsupported response formats can prevent complete service coverage.
Missing metadata remains unknown, and unavailable content stays excluded with
the existing notices.

Deterministic checks use synthetic service bodies, held credential/HTTP replies,
fake native owner snapshots and nonpersistent scene configurations. They check
request parameters, category identity, stale admission, paging/retry, scope
isolation, suggestions, recent searches and unchanged playback. Actual signed-in
coverage, native focus, long French layout and VoiceOver remain runtime checks.
