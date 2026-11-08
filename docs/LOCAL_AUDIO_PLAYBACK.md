# Local audio output ownership foundation

Local audio playback is not enabled. This package defines output admission and
WebKit retirement boundaries for a later shared playback facade. It adds no local
playback controls, AVPlayer, queue, engine activation or live coordinator. Existing
service playback continues through its current owner.

The future facade must be persistent and owned by AppSession. It must reuse the
single queue and the local source, reference, access and prepared-asset contracts;
views must not create players or separate queues.

## Output admission contract

`PlaybackOutputCoordinator` receives injected retirement boundaries and one
`PlaybackOutputAdmission` shared across profiles. Neither is instantiated in the
live app by this foundation. A scope includes session, profile activation and
account generations, the exact queue occurrence, engine kind, item UUID and intent
revision. The adapter must bind that opaque item UUID to a validated source or
local reference before requesting admission; an identifier alone grants no media
access. Item metadata validation remains the source adapter's responsibility.

Every engine revokes commands and events synchronously before the first retirement
wait. A permit is granted only after all exact retirement receipts confirm quiet
and the complete requested scope is still current. Events must match that permit
and scope. A permit grants authority; it does not open a file or start a player.
The eventual engine adapter must check it again immediately before activation.

Quiesce invalidates the active permit immediately. Settlement returns an explicit
`quiet` or `blocked` result within the operation deadline. Missing callbacks keep
resources and admission retained, while the bounded result lets Quit finish.
A profile or source switch must keep the old owner and show a blocked state when
settlement is uncertain. A `Void` settle method, native `isPlaying == false`, or
an issued pause command cannot substitute for that receipt. There is no automatic
resume or retry. A late quiet confirmation can release the old admission but
cannot grant the canceled request; another admission requires a fresh request.

## Exact WebKit retirement

`WebPlayer.revokeOutputForHandoff()` sets an irreversible ownership hold before
callbacks or suspension. It revokes bridge, command, navigation, recovery, rate,
presentation and listening-output scopes. The retired instance cannot play, load,
seek, recover, restore account media or replace its view to remove that hold.

The barrier captures the current WKWebView and all known old views with unresolved
pause or presentation-close receipts. The inventory retains at most seven old
views; the sealed retirement ledger admits at most eight exact targets, including
the current view. Unknown history or overflow blocks output admission. Legacy
service-only swaps keep their existing pause/close calls and timing, with bounded
tracking of unresolved callbacks.

Each exact target must acknowledge sticky media suspension and presentation
closure, followed by a media-state reply of `suspended` or `none`. A merely paused,
playing, missing or unknown state is insufficient. The default response deadline
is three seconds. Timeout and cancellation return blocked receipts without
discarding native resources or admitting another target set. Late callbacks can
finish resource retirement, but the earlier blocked receipt stays blocked.

The native target factory is injected. The new retirement tests substitute
callbacks and never invoke real suspension, presentation-close or media-state APIs. The production adapter
uses Apple's [sticky media suspension](https://developer.apple.com/documentation/webkit/wkwebview/setallmediaplaybacksuspended(_:completionhandler:)),
[presentation closure](https://developer.apple.com/documentation/webkit/wkwebview/closeallmediapresentations(completionhandler:))
and [media-state request](https://developer.apple.com/documentation/webkit/wkwebview/requestmediaplaybackstate(completionhandler:))
APIs, available within the macOS 14 baseline. Apple's
[WKWebView additions overview](https://developer.apple.com/videos/play/wwdc2021/10032/)
distinguishes reversible pause from suspension that blocks page and user resumes.

## Required facade integration

- A retired WebPlayer instance is never unsuspended or reused. After local output
  retires, a fresh web engine needs a valid permit and a fresh facade/host generation.
  A new WebPlayer's internal `webViewGeneration == 0` cannot identify that replacement
  or leave an old SwiftUI host attached.
- Account and login views are also media owners. `WebSession.openLogin()` currently
  restricts autoplay with `mediaTypesRequiringUserActionForPlayback`, which does not
  block an explicit page action. Before local playback is enabled, login/auth views
  must stay media-suspended before loading and through account callbacks and view
  replacement. They must never become a second playback engine. This foundation
  does not change WebSession or claim that integration is complete.
- Local-to-web retirement must mute and pause the exact AVPlayer, detach its item
  and retire observers. The prepared asset and resource lease must remain retained
  for the full native item lifetime. A canceled task or cached paused flag cannot
  release the lease while an item may still read it.
- The shared facade must migrate transport, clocks, state, system media, automation
  and view consumers together. Web-only authentication, presentation and diagnostics
  need explicit adapter paths. Local items must remain excluded from service links,
  remote writes, recommendations and public listening/metadata providers.

## Verification scope

Deterministic tests use fake engines, targets, deadlines and receipts. They cover
joined old-view retirement, callback ordering, bounded inventories, timeouts,
cancellation, late replies, permanent holds, exact scopes, cross-profile admission
and bounded Quit settlement. They do not establish physical silence, actual
WebKit/PiP behavior, AVPlayer retirement, device behavior, local playback, native
layout, VoiceOver or older-system runtime acceptance. Those remain requirements
for the complete integration before local playback is enabled.
