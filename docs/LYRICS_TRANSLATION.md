# Optional lyrics translation

Translate Lyrics opens an optional native sheet on macOS 15 or later. It uses
Apple's public Translation framework on lyrics already supplied by YouTube Music.
It makes no additional lyrics lookup and sends no song title, artist, account
identifier or listening activity to another lyrics service.

The original text, provider credit and service timing remain unchanged. Results
appear in a separate **Untimed Translation by Apple** block. The supplied original
lyric credit is also shown verbatim beside the translated text; absent credits
stay absent. Credits are limited to 4,096 characters and 16 KiB without truncation
and are never passed to Apple's text translator. Translation does not
supply pronunciation, romanization, line alignment or new seek targets. Machine
translation can change meaning, especially for poetry or mixed-language lyrics.

## Explicit actions and models

Opening the sheet starts no translation or model preparation. Load Supported
Languages checks Apple's current language list. Selecting source and target
languages does not start a job. Translate explicitly starts pair validation,
model preparation and one text translation. Missing translation models use Apple's
permission and download UI. Cancel and close immediately remove result authority;
they do not promise to stop or remove shared system downloads.

Apple documents `TranslationSession` text processing as on-device. Apple may
collect app identifier, language and performance metrics, excluding original and
translated text. Language downloads and those metrics mean this is not a promise
of zero network traffic. The sheet discloses this before its action buttons.
See [TranslationSession](https://developer.apple.com/documentation/translation/translationsession)
and [Apple's API and download guidance](https://developer.apple.com/videos/play/wwdc2024/10117/).

The app does not persist translations or language selections, delete system
models, retry automatically or poll for model status. Each input is limited to
16 KiB of UTF-8 text and 500 lines; oversized lyrics remain available in their
original form. Output is limited to 64 KiB before display. Text stays plain text,
without generated links or Markdown actions.

## Ownership and cancellation

Each sheet captures its profile activation, account generation, selected queue
entry, optional exact playback occurrence and the lyrics request's identity,
video and text. Each explicit job also freezes its language pair. The controller
checks that owner before and after language/model preparation and immediately
before passing text to translation. A changed account, profile, selection, source
request, language pair or closed sheet prevents an old result from appearing.
Reopening identical lyrics does not revive an older request's authority.

One process-wide slot prevents overlapping language/model/translation jobs.
Canceling an operation cannot release that slot before its actual asynchronous
call returns. A canceled configuration that never reached an adapter can release
its reservation because it passed no text or model operation. A late callback
cannot take a replacement job's reservation. The app can quit without waiting
indefinitely for an optional system translation or download.

`TranslationSession` remains scoped to the native view and its admitted operation,
with no reusable session or native cancellation callback stored in the app
session. The serial operation runs inline in SwiftUI's supplied task and checks
its cancellation and exact task-host lifetime before each session use and after
each return, before publishing a result. Host
removal revokes that lifetime without calling an invalid session. Task
cancellation and result fences do not prove that a system download has ended. Apple's [view lifetime guidance](https://developer.apple.com/videos/play/wwdc2024/10117/)
also applies to sessions whose results arrive after a view closes.

## Compatibility and verification

The app retains its macOS 14 minimum. Translation controls require macOS 15;
there is no automatic system-popover or external translation fallback on macOS
14. The package explicitly weak-links both `Translation` and its
`_Translation_SwiftUI` overlay. Both framework dependencies must remain weak or
absent in each universal executable slice. The supported SDK exposes Intel and
Apple silicon declarations; that establishes a compile path, not language-model
or hardware acceptance on every Mac.

Injected tests cover source/text bounds, explicit actions, pair changes, held
preparation revoked before text is passed, account/profile/source changes, late
callbacks, retained admission and output validation. They do not instantiate
Apple language APIs, sessions or models. Actual model download consent, language
availability, Intel/Apple silicon execution, macOS 14 launch, native layout,
keyboard and VoiceOver acceptance remain runtime checks.
