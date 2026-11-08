# Optional Discord presence

**Settings > Discord Presence** can share verified song title and artist with
the Discord desktop client running for the same Mac user. It is off by
default. Register your own Discord application, enter its application ID,
then review the disclosure and enable sharing for this listening session.
This app supplies no registered application ID, client secret, or Discord
credentials. Saving an application ID does not connect or start sharing.

Discord may show this activity to other people under your Discord activity
privacy settings. The public activity contains only title and artist text,
with Listening as its activity type. The application ID, current process ID,
and a request nonce are required local routing fields. No YouTube playback
IDs, account identifiers, cookies, tokens, artwork, links, listening counts,
or raw service responses are included. Known uploads, episodes, unknown
content, missing metadata, and text outside the bounded field limits are
excluded. Title and artist must each fit within 128 UTF-8 bytes.

The saved application ID stays in the injected local profile's preferences,
under the existing confirmed account namespace. Signing out, switching local
profiles or accounts, and relaunching require fresh explicit consent. Normal
pause/resume within a consented session may share again only after new
verified eligible content progress. It never resumes playback itself.

## Conditional local integration

Discord's [current IPC documentation](https://docs.discord.com/developers/topics/rpc)
defines native macOS socket discovery, framing, the handshake, and
`SET_ACTIVITY`. Its general RPC authentication instructions cover a broader
interface. The [official SDK client reference](https://discord.com/developers/docs/social-sdk/classdiscordpp_1_1Client.html)
separately documents desktop Rich Presence through the running Discord client
without connecting to the gateway; the [SDK release notes](https://discord.com/developers/docs/social-sdk/release_notes.html)
also identify desktop unauthenticated RPC support.

This adapter attempts only that local presence path. It sends a version-1
handshake, whitelisted `SET_ACTIVITY` commands for this process, and necessary
ping replies. Discord's own [archived clear implementation](https://github.com/discord/discord-rpc/blob/master/src/serialization.cpp)
uses `SET_ACTIVITY` with the process ID and no activity for clearing. No SDK
binary or reference implementation code is bundled. A rejection stops sharing;
the app does not seek Discord credentials, request OAuth, or expand to general
RPC. Actual registered-application acceptance and activity display still need
runtime verification, so availability is conditional.

## Bounds and lifecycle

Discovery examines at most 20 conventional local socket paths. The endpoint
must be a socket owned by the current user, and the connected peer must have
the same user ID. Connect has a two-second total deadline, writes a one-second
deadline, and handshake/command replies a two-second deadline. Frame lengths
are checked before allocation and limited to 16 KiB. Future protocol versions,
invalid frames, unmatched replies, or more than 32 incoming frames within ten
seconds stop the connection. Raw provider errors are never displayed or logged.

Verified content can update presence at most once every 15 seconds. A single
active monotonic watchdog requests clearing after 15 seconds without fresh
verified progress. Pause, seek, ads, buffering, song changes, account detachment,
and normal shutdown revoke pending publication, request the original lease's
clear, and close its connection. No reconnect loop runs in the background;
errors require explicitly enabling sharing again. Off sharing has no recurring
IPC work or watchdog. A connection reader waits only while sharing is active
and handles protocol pings without an idle polling loop.

Permission locks never cover connect, poll, read, handshake, or reply waits.
Only an immediate nonblocking send syscall can be admitted while a lease is
active. Revocation prevents later metadata bytes; a partially sent revoked
frame closes the stream. An already admitted complete command settles before
the original lease's clear, and profile switching waits for that cleanup.
Old clears and connection replies cannot act on a newer lease.

Discord can update its visible activity with a delay. An unconfirmed clear is
reported, the local connection is closed, and you can inspect Discord manually.
Native Settings layout, VoiceOver, real IPC peer/framing behavior, registered
application support, actual clearing, profile switching, and resource use still
require runtime acceptance. Tests use injected channels and synthetic data;
they do not establish real Discord behavior.
