# Quick Commands

Quick Commands is a local typed-command palette for the native macOS app.
Choose **View → Quick Commands…** in the main window, enter one exact command,
and press Return or Run Command. No shortcut is added or changed. Escape closes
the sheet. Ordinary text-editing and playback controls keep their existing
bindings.

G51 is **Partial**: typed playback, navigation, search, timer, volume, and queue
mode commands are implemented. Generated playlists and open-ended requests
remain feasibility work. The palette has no model, cloud parser, new runtime or
dependency, command history, background suggestions, or automatic retries.

## Grammar

Fixed words ignore case and accents. French aliases are accepted alongside the
English forms. Commands are single-line and limited to 1,024 UTF-8 bytes; search
queries also have a 500-character limit. Oversized input is rejected; a truncated
preview is never dispatched without a new edit into the accepted bounds.

| Action | English | French aliases |
| --- | --- | --- |
| Playback | `play`, `pause`, `next`, `previous` | `lire`, `pause`, `suivant`, `précédent` |
| Navigation | `open <destination>` | `ouvrir <destination>` |
| Search results | `search <complete query>` | `rechercher <texte>`, `recherche <texte>` |
| Sleep timer | `timer 30 min`, `timer end`, `timer off` | `minuterie 30 min`, `minuterie fin`, `minuterie arrêt` |
| Volume | `volume 0` through `volume 100` | Same numeric form |
| Seek | `seek m:ss` | `position m:ss` |
| Shuffle | `shuffle on`, `shuffle off` | `aléatoire oui`, `aléatoire non` |
| Repeat | `repeat off`, `repeat all`, `repeat one` | `répétition non`, `répétition toutes`, `répétition une` |

Timer minutes are whole numbers from 1 through 1,440, matching the native timer.
Seek minutes range from 0 through 1,440; seconds must be two digits from 00
through 59, and the target must fit the current recording's known duration.
Decimals, expressions, chained commands, guessed units, and extra playback words
are rejected with specific help. `play jazz` does not become a search or start a
matching result.

Destinations are `home`, `explore`, `library`, `songs`, `albums`, `artists`,
`followed artists`, `playlists`, `liked`, `history`, `uploads`, `podcasts`,
`your podcasts`, `saved episodes`, and `queue`. French aliases include `accueil`,
`explorer`, `bibliothèque`, `titres`, `artistes`, `artistes suivis`, `listes`,
`favoris`, `historique`, `imports`, `balados`, `vos balados`,
`épisodes enregistrés`, and `file`. Artists opens the artists represented in
saved songs; Followed Artists opens followed subscriptions.

The remainder after the first search delimiter stays opaque: punctuation,
capitalization, quotes, further spaces, and words resembling other commands are
passed intact to search. Results use the current search filter and never start
playback. Search is requested only when the command runs.

## State and availability

The palette captures its account generation, optional confirmed profile, and
startup/link intent when opened. It checks them again immediately before
running, consumes a successful UI ticket once, and rejects old input or
presentation tickets. Opening Account, account/session changes, and sign-out
close the palette and clear its input. Commands are not queued for later execution.

Public navigation/search and applicable local controls remain available while
signed out through their existing native action boundaries. Playing the queue
retains the sign-in requirement. Startup-sensitive navigation and queue actions
wait for readiness. Next, Previous, seek, and end-of-recording timers require an
applicable current occurrence; empty queues, unavailable next items, and unknown
durations produce actionable feedback. A submitted command is an action request,
not a claim that remote playback or browsing succeeded.

## Sources and verification

The pinned [Kaset command bar](https://github.com/sozercan/kaset/blob/6a20e60c5dfd552a22e84f36daeef53f94f1ee41/Sources/Kaset/Views/CommandBarView.swift)
uses a macOS 26 model feature.
The native app's strict parser is a separate implementation for its macOS 14
and Intel target. Apple's [CommandMenu reference](https://developer.apple.com/documentation/swiftui/commandmenu)
and [menu guidance](https://developer.apple.com/design/human-interface-guidelines/menus)
support native menu access, clear labels, and an ellipsis for an action that
requires more input.

Deterministic tests use fake command handlers/scopes, a rejecting scene transport,
and disposable preferences. Parser, account/startup/input fences, numeric bounds,
opaque queries, signed-out controls, and native action routing are tested without
live accounts, playback, dialogs, or real preferences. Native layout, focus,
VoiceOver, older hardware/OS behavior, and live command outcomes still require
separate acceptance checks.
