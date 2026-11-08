# Deleting an additional local profile

Settings → Local App Profiles offers Delete for an inactive additional profile.
The default profile, current profile and profile selected for the next launch
are protected. Switch to another profile first if necessary.

The review shows the cleanup scope and any blocked prerequisites. Type the
profile's name to confirm. Cleanup covers only its website store, exact named
Spotlight index, local Last.fm and ListenBrainz credentials, supported settings
and supported local folder contents. It does not delete a Google account,
YouTube library, service history, provider account, or exported file outside the
profile folder.

## Supported cleanup and pending states

This first cleanup path supports empty profile folders, including bounded known
empty subdirectories, and known scalar settings. Populated folders are retained
until their saved-data formats have dedicated cleanup validation. Unknown or
versioned settings, unsupported credentials, symbolic links, unexpected paths,
other app instances and retained website views also block cleanup.

When a prerequisite is blocked, confirmation stages deletion only. The profile
remains listed as Deletion Pending and cannot be opened or renamed. No destructive
cleanup starts while the review contains a blocked prerequisite. Relaunching may
release an old website store, but never starts cleanup automatically. Use Review
Deletion again to inspect the remaining work and confirm it explicitly.

Cancel Staged Deletion is available only while every cleanup step is still
unstarted. It removes the pending marker and retains the profile's data. Once a
step is recorded as running or complete, cancellation cannot restore the profile.
Stop After Current Step waits for the accepted operation's result and leaves
remaining work pending.
Each destructive boundary rechecks every cleanup prerequisite, including changes
made while the review or running-marker write was pending. Quitting revokes the
current session's playback and provider access before waiting for an accepted
cleanup result.

An interrupted operation is checked before retry. Confirmed absence can complete
a step without repeating deletion. A prior Spotlight result with no confirmed
receipt cannot currently be reconciled, so it stays pending. Unexpected data
reappearing after a completed step also blocks further cleanup. The app does not
guess that an irreversible operation succeeded or silently recreate its store.

## Ownership and persistence

Deletion uses a bounded version-two registry journal. The target record remains
until every step has a confirmed result. Running markers are saved and synced
before native cleanup calls; an unconfirmed registry write starts no cleanup.
Revision checks and current activation/account checks reject stale confirmations.
The registry retains malformed, future and unsupported data. Reading a version-one
registry does not rewrite it; confirmed staging is the point of migration.
Older app versions may not understand version two and must retain its file.

A profile's website store and every playback/login web view retain a shared
lifetime lock. Cleanup requires an exclusive lock, so retained views can require
an app relaunch. The app also refuses cleanup while another matching app instance
is running, including older builds that do not implement the lifetime lock.
Apple requires views using a store to be released before
[removing that WebKit profile](https://webkit.org/blog/14423/building-profiles-with-new-webkit-api/).

Filesystem cleanup opens verified directory components without following symbolic
links. It checks current-user ownership and safe permissions for app-owned
directories and private lock files, rejects cross-device traversal, and removes
only empty directories beneath the exact UUID root. Activation also rejects a
symbolic link in an additional profile's directory path. Cleanup never unlinks
saved files. Small empty lock files remain
as coordination metadata to avoid creating two independent locks for one UUID.
Spotlight cleanup targets only this profile's exact named catalog index; it never
uses the default index or wildcard domains. Credential cleanup uses exact local
service/account/persistent-reference queries with interaction disabled; unknown
items are retained. Settings cleanup addresses only the profile's own domain.

Tests use memory registries, fake process inventories and cleanup adapters, held
receipts, isolated schemas and disposable directory-admission fixtures. They
exercise write-ahead ordering, stale admission,
registry conflicts, failure recovery, protected profiles, cancellation and future
data preservation without enumerating processes or invoking cleanup APIs. Actual
WebKit, Keychain, preferences, Spotlight, filesystem cleanup and native layout
remain separate runtime acceptance checks. The source and fake checks do not
establish secure erasure or physical storage behavior.
