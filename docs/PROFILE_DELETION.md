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

Cleanup supports known scalar settings and a bounded inventory of recognized app
metadata. The review shows recognized file and confirmed removal counts. Unknown
files or nested fields, unsupported versions, malformed or oversized archives,
changed file identities, unresolved external writes, unsafe paths and retained
resources keep deletion pending. Other app instances also block cleanup.

Recognized metadata includes the current queue, named queues, collection
organization, library metadata cache, local song rules, local episode progress,
Last.fm and ListenBrainz delivery records, and the local-audio library. Account
folders and filenames must use the exact stored account-hash format. A local-audio
library must identify this additional profile. Bookmarks are validated as bounded
opaque metadata; cleanup never resolves them or visits their target audio files.

Pending service-playlist records are removable only before a remote write was
admitted or after the complete playlist result was confirmed. Creating, known
partial targets and pending batches remain blocked so their recovery evidence is
retained. Profile deletion never tries to finish or undo service writes.

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

Deletion uses a bounded version-two registry archive. Populated cleanup adds a
version-two per-profile journal containing relative metadata names, file identities,
SHA-256 digests, supported schema versions, archive revisions where available and
per-file outcomes. Version-one registries and journals remain readable; unsupported
future data is retained. A manifest is limited to 64 files, 128 folders and 128 MiB
in total, with stricter limits for each format and the existing 64 KiB registry
limit. Unsupported older metadata variants also remain pending.
Cleanup pins queue and organization archives to version two; the other JSON
formats use version one. Stored queue snapshots nested inside named queues also
require version two. Local-audio references require version one at their exact
schema locations. Empty store-lock proofs use version zero. Local-audio and
pending-playlist proofs require an archive revision; other proofs cannot carry
one. Each proof also stores a bounded map of observed normalized version-tag
paths, including nested queue snapshots and local-audio references. The map has
one value per schema path rather than one entry per row. Its root tag is required;
unexpected paths, conflicting versions and future nested versions are rejected.
Lock proofs use an empty map with version zero. These rules also apply when a
journaled file is already absent.

Explicit version and enum tags must survive model decoding unchanged. A supported
model's ordinary UUID casing, date-number representation and omitted defaults
may normalize, but that never authorizes migration of a tagged archive variant.


The target record remains
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
only recognized metadata beneath the exact UUID root on a local filesystem.
Every cleanup boundary validates the full inventory, including newly added or
reappearing files. Each file receives a durable running marker before removal;
its inode, ownership, size, timestamps, digest and schema are checked again before
unlinking. Parent folders are synced and absence is checked. A lost acknowledgment
stays uncertain until another explicit review can establish absence. Changed or
reappearing data is retained. Empty recognized folders are removed last.

Activation also rejects symbolic links in additional-profile paths. Existing
metadata lock files require a nonblocking exclusive lock and are removed last,
while the exclusive profile lifetime lock remains held. The separate
`ProfileLocks/<profile UUID>.lock` remains permanently as coordination metadata.
Local file readers, grants and retained native items also hold shared profile
leases, so a quiet player alone does not authorize cleanup. Audio files, external
exports and bookmark targets are never deleted.
Spotlight cleanup targets only this profile's exact named catalog index; it never
uses the default index or wildcard domains. Credential cleanup uses exact local
service/account/persistent-reference queries with interaction disabled; unknown
items are retained. Settings cleanup addresses only the profile's own domain.

Tests use memory registries, fake process inventories and cleanup adapters, held
receipts, isolated schemas and disposable directory-admission fixtures. They
exercise write-ahead ordering, stale admission,
registry conflicts, failure recovery, protected profiles, cancellation and future
data preservation without enumerating processes or invoking native cleanup APIs.
Disposable metadata fixtures also exercise descriptor-relative inventory and
removal, lock contention, replacement identities, symlinks and external sentinel
preservation. Actual user-profile cleanup, WebKit, Keychain, preferences,
Spotlight and native layout remain separate runtime acceptance checks. The source and fake checks do not
establish secure erasure or physical storage behavior.
