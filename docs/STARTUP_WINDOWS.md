# Startup windows

Settings → Startup separates Launch at Login from the window shown when the app
opens. Launch at Login continues to use the installed app's existing macOS
login-item control. Changing a window preference never registers a login item.
Apple provides [main-app login registration](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp)
separately from scene presentation.

The default, Use macOS Window Settings, preserves system window restoration and
the usual main window. On macOS 15 or later, Main Window, Mini Player and No
Startup Window select a specific next-launch behavior. These explicit choices
disable restoration for this app's windows and suppress other startup windows.
Apple's [default launch behavior](https://developer.apple.com/documentation/swiftui/scene/defaultlaunchbehavior(_:))
alone applies when no saved scenes restore; the app also uses the separate
[scene restoration control](https://developer.apple.com/documentation/swiftui/scene/restorationbehavior(_:)).

Window preferences apply to all local profiles at the next launch. They do not
close current windows, change the selected profile or start playback. The Dock
and menu bar remain available, including with No Startup Window. This option
does not hide the app's Dock icon.

macOS 14 keeps its existing main-window and system-restoration behavior. Saved
choices from newer versions stay stored. Unknown settings also stay stored and
use the safe system behavior until an explicit new choice is made. The app does
not change global macOS restoration settings or remove saved-state folders.

The profile owner starts independently of the main window or menu-bar popover.
Incoming music links, Spotlight selections and explicit window requests wait for
the resolved active profile. Requests bound to a revoked activation are dropped.
An explicit link or navigation request shows the main window; automatic launch
still leaves playback paused. Song links retain their existing sign-in checks.

Dock or Finder reopening with no visible windows requests the main window once.
With visible or minimized windows, normal AppKit behavior continues. Apple's
[reopen delegate contract](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldhandlereopen(_:hasvisiblewindows:))
distinguishes those cases and lets an app handle a custom request itself.

If a current explicit window request or Mini Player startup cannot be presented, a small recovery
window offers Use Default Startup and Quit. It changes the preference only when
clicked and quits through normal profile and playback settlement. Cancel keeps
the saved preference. Choosing No Startup Window alone never opens recovery.

The existing music-player popover and mini-player include Settings and Quit.
This follows the separation between login behavior and visible controls found
in [Spotify's startup guidance](https://community.spotify.com/forum/en/kb/articles/777-stop-spotify-from-opening-automatically-on-desktop)
and [Raycast's native settings](https://manual.raycast.com/settings).

## Verification

`Scripts/with-xcode.sh swift test --jobs 1 --filter 'StartupWindow|AppAutomation|AppProfile|SceneCheck'`
runs the focused checks. Startup policy and lifecycle tests use injected preferences, profile readiness,
presenters, recovery controls and held bootstrap operations. No real login item,
user profile, permission prompt or playback is used by those tests.

The opt-in packaged scene check accepts `--check-ui-scenes --check-id UUID
--check-startup-window none` or `mini`. It uses a disposable preference domain,
nonpersistent WebKit, disabled output and a rejecting network transport. It
checks startup ownership and the status-label window presenter before requesting
the main window and running the normal render revisions.

On macOS 26.6 with an Apple silicon debug package built using the macOS 27.2 SDK,
both No Startup Window and Mini Player passed 100 rendered revisions. The owner
started before the main window or popover opened, the status-label presenter was
available, and an explicit request attached the main window. These isolated
checks used no authenticated session, network requests or playback output.

Actual login/approval behavior, restoration across quit or logout, hidden or
removed menu icons, VoiceOver, and playback with the main window never mounted
remain separate runtime acceptance checks on supported Macs. macOS 14 alternate
window suppression is not implemented by an unverified AppKit workaround.
