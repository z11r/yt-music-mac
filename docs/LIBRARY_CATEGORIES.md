# Library categories

[Search Your Library](LIBRARY_SEARCH.md) sends explicit category searches to
the signed-in service library. It is separate from filtering already loaded rows.

Library provides All, Playlists, Songs, Albums, Artists and Followed Artists.
These are separate authenticated service destinations. Liked Songs remains a
separate playlist destination; it can overlap the saved-song library and can
include liked videos. Uploads remain in their own account library.

Artists lists the artists associated with the account's saved songs. Followed
Artists lists subscriptions. An artist appearing in the song library does not
establish that the account follows that artist; follow controls still require
an authoritative subscription state.

Songs uses the native song table, with filtering and sorting over loaded rows,
selection, metadata navigation and complete-collection queue actions. Load More
fetches additional rows. The category picker does not offer a second card filter
for that song table. Other library categories retain their loaded-card controls.

The request paths follow [ytmusicapi's library implementation](https://github.com/sigma67/ytmusicapi/blob/206d470bd857dde9e4c588170a23188037e03ad5/ytmusicapi/mixins/library.py).
Tests verify the distinct browse IDs and required authentication. The existing
navigation diagnostic covers albums, followed artists and history; its earlier
live result does not establish coverage of the new Songs and Artists destinations.
Signed-in paging, displayed totals, keyboard use and VoiceOver remain checks for
the combined app.
