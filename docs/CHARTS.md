# Chart countries

Open Explore, choose Charts, then use the country menu. The menu contains only
country tokens offered by that chart response. Country names use the Mac's
locale; Global is shown only when the service offers its global token. Missing
country controls leave the ordinary chart shelves available.

The label comes from the service's filter header. Sending a country request
alone does not establish that the service accepted it. Shelves and playlist
names stay as returned by YouTube Music; the app does not calculate chart ranks
or add missing daily, weekly, genre, or language charts.

Country choices belong to the session that returned them. Account/session
changes clear the choices and return a selected-country page to the default
Charts request. Paging uses the returned continuation and keeps the normal
account and navigation cancellation checks.

[YouTube's chart guide](https://support.google.com/youtubemusic/answer/9014376?hl=en)
describes regional charts. The request shape and offered-token path follow
[ytmusicapi's chart implementation](https://github.com/sigma67/ytmusicapi/blob/206d470bd857dde9e4c588170a23188037e03ad5/ytmusicapi/mixins/charts.py).
Synthetic fixtures check country choices, malformed tokens, session isolation,
missing controls and pagination. Signed-in regional results, keyboard focus,
long country names and VoiceOver remain runtime checks.
