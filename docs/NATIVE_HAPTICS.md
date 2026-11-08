# Optional native haptic feedback

Settings → Haptic Feedback offers a separate, default-off option for each local
profile. Enabling it requests brief tactile feedback for successful direct queue
moves, Undo, Shuffle and Repeat changes in native controls. Existing visual state
and accessibility labels remain available.

The app uses AppKit's generic feedback pattern with immediate timing. A supported
Force Touch trackpad is needed, and macOS can suppress feedback based on input,
accessibility and user settings. A request does not prove that hardware produced
feedback. The app does not inspect devices or report a capability result.

Only direct native button, menu, accessibility-action and completed row-move
callbacks use this feature. Shared playback and queue methods, Quick Commands,
on-device command review, Apple events, Shortcuts, autoplay, provider callbacks,
recovery, sliders and progress updates do not request haptics. A no-op move or
unchanged queue state produces no request.

## Scope and limits

The option is stored as a Boolean in the profile's existing injected preferences.
Missing, unsupported or wrongly typed values leave it off. It does not enable
another profile's option or alter system preferences. Turning it off suppresses
feedback from already rendered controls immediately.

Native actions capture the account generation, session owner and queue revision
when rendered. A changed account or queue, busy account, suspended profile or
shutdown rejects the stale action before mutation or feedback. The scope is
checked again after the synchronous local action. No provider acknowledgment or
delayed completion can produce feedback later.

At most one request is admitted every 150 milliseconds. Nonfinite or negative
clock readings produce no request; a backward reading rebases the short interval
and suppresses that request. This uses only bounded monotonic state, with no task,
timer, event monitor, polling, hardware probe or background worker. The native
default performer is obtained anew only when feedback is explicitly admitted.
Off state performs no haptic or clock work.

## Platform and verification

Apple's [haptic performer documentation](https://developer.apple.com/documentation/appkit/nshapticfeedbackperformer/perform(_:performancetime:))
requires user-initiated actions and explains system suppression. Its
[default performer](https://developer.apple.com/documentation/appkit/nshapticfeedbackmanager/defaultperformer)
accounts for the current input device, accessibility settings and user
preferences; applications should request it for each use. The installed AppKit
header and [manager API](https://developer.apple.com/documentation/appkit/nshapticfeedbackmanager)
declare availability from macOS 10.11, within this app's macOS 14 baseline.

Tests inject disposable preferences, a fake clock and a fake performer. They
verify direct changed-state admission, duplicate occurrence preservation,
automation silence, stale ownership, immediate opt-out, clock anomalies and
profile isolation without invoking the real performer. Hardware feel, input
device changes, native layout, VoiceOver and older-system runtime behavior remain
separate acceptance checks. Source compilation and fake call counts establish
neither physical feedback nor its quality.
