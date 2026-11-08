# Local audio engine and resource ownership

The local engine adapter owns one lazy AVPlayer and one current item. It has no
queue, app session, service client or window. The app facade must supply an exact
bound output permit and a separately prepared local source before activation.
Native playback, decoding and permission behavior still need runtime verification.

## Output and events

Each engine has a stable UUID and object identity. Commands check their current
permit immediately before effects. A preparation is consumed once and must match
its profile, source, item request and queue occurrence. Ordinary command retargeting
keeps the current player and item; next-item preparation mutes and pauses them.
Replacement removes old observers and detaches the old item before the new item
can become current.

Media callbacks capture immutable event bindings for their actual native item.
Old state, end and seek callbacks cannot acquire a replacement's scope. Ready,
seek and retirement waits have bounded deadlines. End events are accepted once,
and only the app queue owner chooses the next occurrence.

Retirement permanently holds that engine against later activation, play, unmute
or seek. It confirms quiet only after the same native player's item, mute, rate,
paused and external-playback state agree. Unknown state blocks handoff. A late
quiet observation can release output admission without reviving old intent or
changing an earlier timeout receipt. This checks native state, not downstream
hardware buffers.

## Files and profiles

File operations require a current authorization and a profile lifetime. The
native provider checks the registry and pending deletion before acquiring shared
profile ownership, then checks again. Storage identity is the validated profile
context's website-data UUID. The default profile remains protected; it cannot be
selected by a caller-supplied default flag.

Resource close requests wait for outstanding native-use tokens. Acyclic holders
on AVURLAsset and AVPlayerItem retain these tokens and profile ownership through
the actual native object lifetime, including canceled reads and detached items.
Output quiet does not mean a file grant is no longer in use.

A factory-owned reference registry is shared across profile reactivation. Its
bounded, process-local counts include pending reads and retained native owners.
An exclusive record-change reservation blocks unrelated new uses through CAS
settlement. Its private review token permits same-record reauthorization without
playback membership proof. Releasing the reservation does not erase retained
review uses. This does not revoke grants held by another app process. Every new
library access reloads authoritative membership; metadata CAS uses its separate OS
lock. Removing a record never deletes the audio file.

Unpersisted import and reauthorization sources can be inspected privately but
cannot activate the engine. Playback preparation needs a library access proof
created by a fresh validated lookup. Source failures become fixed English/French
issues; native error descriptions, paths and bookmark data do not enter playback
events or automation status.

Tests use fake drivers, clocks, prepared sources and profile ownership. They
exercise control authority, retained lifetimes, cancellation and deadlines without
creating AV media objects, obtaining file grants or producing audio. The native
adapter still needs packaged-app checks on Intel/macOS 14 and Apple silicon.
