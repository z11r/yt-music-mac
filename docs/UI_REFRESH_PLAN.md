# Interface refresh plan

Proposed November 14, 2026, against feature checkpoint `60794cc`. This plan
changes presentation around the existing player, library, lyrics and queue.
It does not describe an implemented redesign.

The recommended direction is a native Mac interface with more emphasis on
artwork: a distinct Home composition, larger collection headers, restrained
colors drawn from covers, and a clearer persistent player. Keep the current
window structure, keyboard behavior and shared playback owner.

Start with Home and the player bar. Review that pair before extending the
design to collections, search and playback windows. The release gates in
[Compatibility](COMPATIBILITY.md) and [Testing](TESTING.md) still apply.

## What needs attention

These observations come from the source at the checkpoint above. They are
design hypotheses to check against rendered screens, not a completed visual
or usability test.

| Current presentation | Proposed change |
| --- | --- |
| Home, Explore, artist pages and much of Library share the same shelf composition and 176-point cards. | Give Home a clear first choice; use compact song rows, cover shelves and artist portraits for different content. |
| Content and expanded playback use the same window background. | Establish separate navigation, content and playback surfaces; add a limited artwork tint to headers and the player. |
| Collection covers are 120 points, smaller than browsing cards. | Give album and playlist headers larger covers and clearer title, metadata and action hierarchy. |
| The player has 50-point artwork, a 34-point play/pause control and several adjacent secondary icons. | Increase artwork and transport emphasis; group secondary actions and adapt them to available width. |
| The sidebar has many library destinations at equal prominence. Queue access appears in both toolbar and player. | Group destinations, preserve direct access to common ones, and use the player as the main queue entry point. |
| Expanded playback already has artwork, lyrics/queue access and shared controls, but uses a plain vertical stack. | Give it a deliberate listening layout and an optional adjacent lyrics or queue panel. |

Accent preferences, library categories, local pins, lyrics and expanded playback
already exist. This work should use those implementations. Adding another
accent picker or another playback window would not address the composition.

## Reference patterns

The recommendations are design judgments based on official documentation and
published images. The products were not benchmarked or tested side by side.
Product images show particular versions and states, not every available layout.

| Reference | Useful pattern | Application here |
| --- | --- | --- |
| [Apple Music MiniPlayer](https://support.apple.com/en-is/guide/music/mus71d7dcfce/mac) | Artwork dominates the expanded compact player, with lyrics, queue and transport close at hand. | Let the current cover anchor playback; keep frequently used actions easy to find at both compact and expanded sizes. |
| [Spotify desktop design, June 2023](https://newsroom.spotify.com/2023-06-20/spotify-desktop-experience-redesign-your-library-now-playing-views-customize/) | Resizable library and Now Playing panels support browsing while listening. This is a historical design reference. | Keep the queue optional and resizable. Give saved music useful navigation space without forcing three columns at narrow widths. |
| Plexamp [October 2026 desktop layout](https://forums.plex.tv/t/plexamp-release-notes/221280?page=6), [collection headers](https://forums.plex.tv/t/plexamp-release-notes/221280/120) and [stable release](https://forums.plex.tv/t/plexamp-release-notes/221280/129) | Its desktop work combines an artwork-colored player, large collection banners and reduced controls in narrow windows. | Sample color from the displayed cover, enlarge collection identity, and define a compact player layout. Keep background color static between track changes. |
| [Kaset](https://sozercan.github.io/kaset/) | Its published music screen combines native navigation, prominent selection, cover shelves and a distinct bottom player. | Keep familiar Mac navigation and improve the separation of the player from browsing. Limit transparency so text remains legible. |
| [Roon music discovery](https://roon.app/en/music/discovery) | Music is organized around meaningful artist, recording and composition context. | Give artist and album pages their own hierarchy and use available metadata to explain the music. Additional editorial or recording data needs a real source. |

Apple's [color guidance](https://developer.apple.com/design/human-interface-guidelines/color)
supports semantic colors, appearance variants and attention to artwork behind
controls. Use this as a constraint on custom tinting, with visible state labels
and focus indicators that do not depend on color alone.

## Proposed screens

### Home

Keep the toolbar and a compact page heading. Below them, present one prominent
collection from the existing Home response, using its actual artwork, title
and source section label. Prefer a collection that already has an Open action;
show a separate Play action only when its playback target is known. Keep the
choice stable until the page changes. Do not automatically rotate the feature.

Compare two compositions in the first mockup: a 240–280-point feature area and
a smaller 160–190-point lead row. Prefer the larger version only if a useful
second section remains visible at the normal window size. At 860 × 600, use the
compact version. If there is no suitable collection, begin with the normal
service shelf instead of manufacturing a featured recommendation.

Below the lead item, vary the layout by content: compact rows for song-only
sections, square covers for albums and playlists, and circles for artists.
Retain service ordering and labels. Mixed or unknown sections keep the existing
card fallback. Show See All only for a real destination. Pins or history can
supply a small quick-access row later; they must retain their actual scope and
must not be relabeled as service recommendations.

### Album, playlist and artist pages

Start album and playlist headers with a 200–240-point cover, a prominent title,
two short metadata lines, and one clear Play All action beside Shuffle and More.
Use the existing full-collection commands and their loading/cancellation states.
Keep filtered or selected playback separately labeled.

Use a soft tint behind the header, fading into the normal track-list surface.
Keep the track list compact and aligned, with stable row heights and distinct
selected, hovered, focused and currently playing states. Color alone must not
distinguish them. Retain multi-selection and occurrence-specific queue actions.

Give artists a portrait, name and available description before albums and songs.
Use a wide image only when suitable source artwork exists; enlarging a small
portrait into a blurry banner should fall back to a portrait header. Metadata
that is absent stays absent. Keep loaded counts distinct from service totals.

### Player bar

Use three stable groups: track identity on the left, transport and progress in
the center, and volume plus secondary destinations on the right. Start with
56–64-point artwork, a 40-point play/pause control, and an 88–96-point normal
bar height. Errors and episode controls may need extra space; do not conceal
them to meet a height target.

Use a faint cover tint behind a readable playback surface. Keep the existing
control accent for interactive state. Clicking the cover opens the existing
Now Playing window. Lyrics and queue remain direct actions at normal width;
video, output and window options can share a More menu. At narrow widths,
secondary destinations move into that menu before track identity or transport
is squeezed. Keep Play/Pause, Previous, Next, progress and Queue available.

Remove the duplicate queue toolbar button after confirming the player action,
View menu and shortcut remain discoverable. Preserve the existing native seek
slider, elapsed-time formatting and focus-aware keyboard commands.

### Sidebar, search and library

Keep Home, Explore, Library, Liked Songs and History easy to reach. Organize the
remaining existing destinations into collapsible Library, Podcasts and Local
sections, with a separate Pinned section for existing local pins. Preserve all
routes and remember disclosure state. Labels and selection should carry the
hierarchy; avoid coloring every symbol.

Keep catalog search in the toolbar and preserve its explicit library scope.
Within search results, use song rows and collection cards instead of making
every match equally large. Keep filter focus stable while requests finish.
Library should remain an efficient grid or list rather than another featured
Home screen. Keep local organization visibly separate from service data.

### Now Playing, lyrics and queue

Keep the existing window and playback owner. On a wide Now Playing window,
place large artwork and track controls beside an optional Lyrics/Queue panel.
At compact sizes, show one panel at a time with clear navigation back to the
artwork. Preserve standalone lyrics and queue windows and their shortcuts.

Use one restrained background treatment derived from the cover. Keep active
lyrics readable without scaling surrounding lines or repeatedly moving focus.
Queue rows retain duplicate-entry identity, manual/radio distinctions and
keyboard reorder/remove commands. Backgrounds and decorative indicators do
not run continuous animations.

## Shared visual rules

These are starting dimensions for prototypes, measured in points. Adjust them
after checking real text, artwork and window sizes.

| Element | Starting rule |
| --- | --- |
| Page spacing | 24–32 outer padding; 28–36 between sections; 8–12 within a title group. |
| Covers | 176–200 in normal shelves; 200–240 in collection headers; 56–64 in the player. |
| Typography | System text styles; clear page/section/body hierarchy; semibold titles; secondary metadata; monospaced elapsed times. |
| Surfaces | Semantic sidebar, content and playback backgrounds; subtle dividers where structure needs them. |
| Artwork tint | Begin around 6–10% in light appearance and 10–16% in dark; validate actual contrast before choosing final values. |
| Controls | Existing system or chosen accent; prominent primary Play action; explicit state and visible keyboard focus. |
| Motion | Short, event-driven artwork/state transitions, with immediate updates under reduced motion. No animated ambient background. |

Use system/light/dark appearance as already configured. Artwork tint and control
accent serve different purposes: a cover change must not overwrite the chosen
accent or make interactive states change meaning. Missing or unsuitable artwork
uses the normal semantic surface. Increase Contrast and Reduce Transparency
use opaque surfaces and the existing accessible control fallback.

For a first color implementation, derive one muted color from a small decoded
image off the main thread. Reuse the artwork pipeline; do not download the same
cover for color extraction. Bound and evict palette entries alongside artwork,
reject stale results after a track/profile change, and update only when artwork
changes. Keep color computation out of per-second playback updates.

Layout decisions must use available content width, including the space taken
by the sidebar and inspector. As a starting rule, compress or stack collection
headers below 620 points of content width. Keep the existing 860 × 600 minimum
usable with either panel open. Verify the narrowest combination rather than
assuming window width equals content width.

## Delivery order

Each implementation batch should have its own commit and reviewable before/after
screens. The first two batches are the initial trial, not a commitment to every
later layout decision.

| Batch | Deliverable | Completion check |
| --- | --- | --- |
| 1. Baseline and mockups | Record the exact current build; capture Home, a long playlist, search and Now Playing. Mock up the two Home compositions and revised player in light and dark. | Compare the same content at 1180 × 780 and 860 × 600. Choose the composition with clear track identity, primary action and visible browsing content. Record the chosen design. |
| 2. Home and player trial | Shared spacing/surface rules, revised Home layouts, bounded cover-color extraction and adaptive player. | A usable native build shows the change with real data. Search, play, pause, seek, skip and queue still work; missing art, long titles and reduced effects remain usable. |
| 3. Collections | Album/playlist/artist headers and aligned track rows. | Small and large collections preserve order, selection and full-collection playback; loaded totals and errors stay honest. |
| 4. Navigation and search | Sidebar grouping, pins presentation, result layouts and library density. | Common destinations stay easy to reach; all existing routes, scope labels, search editing and keyboard focus survive. |
| 5. Listening views | Revised Now Playing and adjacent lyrics/queue presentation. | Opening, resizing and closing every playback window preserves the same session, track and queue occurrence. |
| 6. Acceptance | Matched screenshots, accessibility checks, localization review and repeated resource measurements. | Complete the checks below and record remaining hardware/live limitations separately. |

The main implementation areas are `Views/MusicContentView.swift`,
`Views/PlayerViews.swift`, `Views/ArtworkView.swift`, `Views/RootView.swift`,
`Views/ExpandedPlayerView.swift`, `Views/LyricsPanel.swift` and
`Views/QueueView.swift`. Extract reusable presentation components as needed;
do not move playback ownership into them. Extend existing scene fixtures for
deterministic visual states, without connecting fixture runs to account data.

## Acceptance

- Capture the same representative content in light/dark at 860 × 600,
  1180 × 780 and 1440 × 900, with sidebar/queue combinations. Check long English
  and French text, missing artwork, empty results, loading, offline, signed-out,
  buffering and failed-playback states. No action may overlap another control
  or become unreachable.
- Review bright, dark, monochrome and busy covers. Measure text against the
  actual composed surface; target at least 4.5:1 for ordinary text and 3:1 for
  large text and meaningful control boundaries. Check focus and selection
  independently of artwork tint. Verify VoiceOver and Full Keyboard Access.
- Complete a keyboard-only path through search, a collection, playback,
  queue edits and lyrics. Text editing must retain ordinary spaces and native
  shortcuts. Hover-only controls must have focus and menu equivalents.
- Verify resize, back navigation, account/profile changes and closing/reopening
  playback windows. Existing disabled service edits remain disabled. Do not add
  unavailable rating, download or device actions just to complete a layout.
- Run existing playback, artwork, queue and keyboard regression checks. Add
  focused tests for palette caching/cancellation and new adaptive state logic;
  use rendered review for subjective spacing and hierarchy.
- Compare release builds using the same machine, content, window geometry and
  power conditions. Repeat paused, visible-playback, scrolling and long-queue
  workloads at least three times. Report app and WebKit CPU/memory separately,
  label RSS versus physical footprint, and investigate repeatable regressions.
  Set budgets from that baseline; no performance improvement is claimed here.
- Confirm that tinting creates no continuous idle work, repeated downloads or
  unbounded cache growth. Repeat the existing Intel/Apple silicon build checks;
  retain macOS 14 runtime and physical-device gates as distinct requirements.

The first decision is the Home/player composition. A more distinctive screen
should make it easier to choose music and understand playback while preserving
the app's native controls and resource goals.
