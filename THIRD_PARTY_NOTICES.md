# Third-party notices

## Kaset

Parts of the YouTube Music request handling and response parsing are adapted
from [Kaset](https://github.com/sozercan/kaset) at commit
`6a20e60c5dfd552a22e84f36daeef53f94f1ee41`:

- `Sources/Kaset/Services/API/YTMusicClient.swift`
- `Sources/Kaset/Services/API/InnerTubeSupport.swift`
- `Sources/Kaset/Services/API/Parsers/HomeResponseParser.swift`
- `Sources/Kaset/Services/API/Parsers/SearchResponseParser.swift`
- `Sources/Kaset/Services/API/Parsers/SearchSuggestionsParser.swift`
- `Sources/Kaset/Services/API/Parsers/PlaylistParser.swift`
- `Sources/Kaset/Services/API/Parsers/ParsingHelpers.swift`
- `Sources/Kaset/Services/API/Parsers/ParsingHelpers+Playlist.swift`
- `Sources/Kaset/Services/API/Parsers/PlaylistEditability.swift`
- `Sources/Kaset/Services/API/Parsers/SongMetadataParser.swift`
- `Sources/Kaset/Services/API/Parsers/RadioQueueParser.swift`
- `Sources/Kaset/Services/API/Parsers/LyricsParser.swift`
- `Sources/Kaset/Models/Lyrics.swift`
- `Sources/Kaset/Models/SyncedLyrics.swift`

Synthetic editability and like-state tests also use response shapes documented in
`Tests/KasetTests/PlaylistParserTests.swift` and
`Tests/KasetTests/RadioQueueParserTests.swift` at the same revision.
Synthetic lyrics tests also use response shapes documented in
`Tests/KasetTests/LyricsParserTests.swift` at that revision.

The parser regression tests reuse these sanitized fixtures from
`Tests/KasetTests/Fixtures/` at the same revision:

- `home_response.json`
- `search_response.json`
- `playlist_detail.json`
- `search_tabbed_mixed.json`
- `search_later_flex_columns.json`
- `search_playlist_watch_endpoints.json`
- `search_direct_item_section.json`
- `search_music_shelf_continuation.json`
- `search_top_result_watch_endpoints.json`
- `album_playlist_without_header.json`

The playback bridge also uses Kaset's player identity and navigation approach
as a reference. Changes in this project have not been reviewed by its authors.

The keyboard shortcuts follow `docs/keyboard-shortcuts.md` at the same revision.
Removing playback shortcuts from the menu while a text field has focus is based
on `Sources/Kaset/Utilities/TextInputFocusState.swift` and the playback commands
in `Sources/Kaset/KasetApp.swift`. The song notification setting and the
mini-player's floating level take the same approach as
`Sources/Kaset/Services/Notification/NotificationService.swift` and
`Sources/Kaset/MiniPlayerWindowController.swift`.

MIT License

Copyright (c) 2025 sozercan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
