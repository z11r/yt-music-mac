# Localization

English is the development language; French is the first additional locale.
Native translations live in each target's
`Resources/<language>.lproj` directory. SwiftPM processes these resources with
`defaultLocalization` set to English. The app follows macOS system and per-app
language preferences; it does not write a language override.

Package resources alone do not cover every lookup. SwiftUI literals and App
Intents use the main bundle, while native String-valued labels and errors use an
explicit target bundle. Packaging therefore copies the three target bundles and
the app's localized tables into the main app resources. Package checks verify
both locations before signing validation.

Translate native controls, menus, accessibility labels, and explanatory errors.
Keep service titles, artists, album names, lyrics, account values, user-entered
names, stable identifiers, API fields, and diagnostic codes verbatim. Use the
target localization helper only with a static native key. Insert variable text
through format arguments rather than using it as a localization key.

Keep placeholder types and positions intact. Counted nouns use `.stringsdict`
plural rules; each rule needs its numeric type and `other` form. Automated tests
compare language key sets, placeholder signatures, and packaged resource paths.
These checks do not establish translation quality or runtime accessibility.

`AppShortcuts.strings` supplies translated invocation phrases. Preserve the
`${applicationName}` token. Intent titles, parameters, descriptions, and short
titles use the app's `Localizable.strings` table. These resources do not establish
Siri availability or Shortcuts registration on a particular Mac.

Run the resource tests without changing system preferences:

```sh
Scripts/with-xcode.sh swift test --jobs 1 --filter LocalizationTests -Xswiftc -emit-localized-strings
python3 Scripts/check-localizations.py --stringsdata-root .build
```

The second check compares compiler-extracted SwiftUI and App Intents keys with
the catalogs. It also checks explicit native lookups in all three targets. When
adding a computed String label, use its target's localization helper; SwiftUI
does not infer localization from a String variable. Keep service metadata as a
String value instead of converting it to `LocalizedStringKey`.

For layout acceptance, use an isolated app configuration with long localized
copy and both layout directions. Check minimum window sizes, sidebar width,
menus, sheets, player controls, truncation, alignment, semantic arrows, focus
order, and selectable service text. Test French, a long-text pseudo-localization,
and right-to-left layout separately. VoiceOver and keyboard-only checks require
runtime verification; they must not be inferred from resource or build tests.
