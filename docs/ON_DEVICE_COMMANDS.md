# Reviewed on-device commands

On-device Command Review is an optional interpretation step for the existing
typed commands. Enable it in Settings → On-device Commands, then choose
View → On-device Command Review… in the main window. Enter one request,
choose Interpret Request, inspect the proposed exact command, and choose
Run Proposed Command only if it matches your intent. Interpretation never
dispatches an action automatically. Editing the input revokes its proposal.

This option is off by default and belongs to the current local profile.
The adapter requires macOS 26, an eligible Apple silicon Mac, Apple Intelligence
enabled, a ready system model and a supported current language. Each unavailable
state keeps [exact Quick Commands](QUICK_COMMANDS.md) available. The app does not
enable system settings, start model downloads or use a cloud fallback.

## Supported requests

The closed action set covers current-queue Play, Pause, Next and Previous;
fixed app destinations; search; volume; seek; sleep timers; shuffle; and repeat.
Requests for named recordings, generated playlists, arbitrary service actions
or multiple actions are unsupported. Uncertain output is rejected. Review is
still required because a structurally valid interpretation can be wrong.

Values must be explicit. Use digits for volume and timer minutes, `m:ss` for
a position, and double quotes around a search query. The native validator
requires the numeric token or complete quoted query to match the source text.
It does not fill missing values, convert hours to minutes, turn spelled numbers
into digits, guess destinations, or invent media identifiers. Search preserves
the quoted text and opens results without selecting or playing a recording.
The ordinary exact-command limits and current playback requirements still apply.

For example, `Set volume to 50 percent` can propose `volume 50`, and
`Find "Björk live"` can propose `search Björk live`. `Make it louder` cannot
supply an invented volume. `Pause and next` is a compound request and is rejected.
These examples describe accepted validation forms, not measured model accuracy.

## Privacy and lifetime

Only the explicitly submitted input reaches Apple's on-device
[`SystemLanguageModel`](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel).
The app adds its fixed action instructions and schema, with no account,
queue, recording, listening or credential metadata. Each admitted request uses
a fresh session with no tools. The app does not prewarm the model, retain a
request history, export the framework transcript or submit feedback attachments.
The visible draft and proposal remain in memory until cleared.

Input is limited to 512 UTF-8 bytes, app instructions to 3,072 bytes, generated
output to 256 tokens and the decoded schema to 4,096 bytes. A shared admission
gate permits one underlying generation across profiles. Cancel, edits, close,
opt-out, account changes and profile quiescence revoke review and Run immediately.
If a provider has not finished responding to cancellation, it keeps its
admission until it returns; reopening cannot accumulate additional sessions.
Profile shutdown waits for that admitted work to settle.

Running rechecks the local profile, account generation, startup/link intent,
readiness, queue revision, current occurrence and input ticket. Tickets are
consumed before the existing exact parser, current-state validator and native
action boundary dispatch a command. Commands are never queued for a later state.

## API and acceptance

The adapter follows Apple's
[availability and response guidance](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)
and [guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation).
It uses the macOS 26 `SystemLanguageModel.default`, availability checks,
`LanguageModelSession`, `Generable`, `Guide.anyOf` and bounded generation options.
The macOS 14/Intel path does not use the model API. There is no new package
dependency or shortcut.

Deterministic tests use fake availability, providers, state snapshots and
disposable preferences. They establish validation, cancellation, admission and
dispatch behavior. No real model, download, settings change, account or external
request is used in those tests. Real model accuracy in English and French,
availability transitions, cancellation latency, resource use, native keyboard
and VoiceOver behavior, and older hardware/OS launch remain runtime acceptance
checks. G51 remains **Partial**; playlist construction is a separate feature.
