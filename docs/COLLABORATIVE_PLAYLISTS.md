# Collaborative playlists

Native collaboration management is not implemented. Existing playlist reads
and separately gated edits do not establish collaborator roles or permission
to manage invitations. Production remote-edit gates remain off.

## Current service workflow

Google's [desktop YouTube Music guide](https://support.google.com/youtubemusic/answer/7205933?co=GENIE.Platform%3DDesktop&hl=en)
describes opening playlist Edit, choosing Collaborate, selecting collaborators,
and sharing an invitation link. It describes collaborators as able to share,
sort, add, and edit. The available service controls must establish the signed-in
account's actual authority; these instructions do not grant every collaborator
owner-level access.

Google's [YouTube collaboration guide](https://support.google.com/youtube/answer/6109639?co=GENIE.Platform%3DDesktop&hl=en)
also documents these boundaries:

- An invitation requires a public or unlisted playlist. The service asks to
  make a private playlist shareable; native collaboration must never change
  visibility without a separate explicit choice.
- Turning collaboration off removes collaborators. Leaving removes the
  person's ability to contribute and their collaborator listing, while their
  earlier contributions remain.
- A contributor can remove their own additions; the owner can also remove
  those additions. Seeing the playlist or its editable header does not prove
  permission to remove another person's occurrence.
- Voting can affect displayed order. Everyone, Collaborators only, and Off
  are distinct settings; collaboration enables voting by default, subject to
  service restrictions. Native sorting must remain separate from service order.

The Music guide separately describes account/content restrictions and Taste
Match playlists. Taste Match's mobile creation/joining rules, participant limit,
and automatic updates do not define ordinary collaborative playlist behavior.

## Established request shapes and remaining gaps

Reviewed November 8, 2026. The pinned
[ytmusicapi playlist source](https://github.com/sigma67/ytmusicapi/blob/206d470bd857dde9e4c588170a23188037e03ad5/ytmusicapi/mixins/playlists.py)
and [current revision](https://github.com/sigma67/ytmusicapi/blob/488dbf31d8f9173331c80375fdc2fb6de6d45f6d/ytmusicapi/mixins/playlists.py)
establish authenticated `browse/edit_playlist` request shapes:

| Operation | Action and evidence |
| --- | --- |
| Create invitation | `ACTION_CREATE_COLLABORATION_INVITE_LINK`; a successful response supplies a link containing `jct`. |
| Join | `ACTION_JOIN_COLLABORATION` with the playlist ID and `joinCollaborationToken`; joining also adds the playlist to the library. |
| Close contributions | `ACTION_SET_CLOSED_TO_CONTRIBUTIONS` with `closedToContributions: true`. |

The [reference documentation](https://ytmusicapi.readthedocs.io/en/stable/reference/playlists.html)
notes that private playlists cannot be used by collaborators, enabling returns
a new invite token, and joining an existing membership can return an error.
An error alone cannot establish whether membership or an earlier write changed.

The [current header parser](https://github.com/sigma67/ytmusicapi/blob/488dbf31d8f9173331c80375fdc2fb6de6d45f6d/ytmusicapi/parsers/playlists.py)
recognizes a collaboration-specific facepile panel and returns a supplied label
and avatars. This is limited display metadata, with no complete membership
roster or per-member authority. The pinned/current
[Kaset client](https://github.com/sozercan/kaset/blob/6a20e60c5dfd552a22e84f36daeef53f94f1ee41/Sources/Kaset/Services/API/YTMusicClient.swift)
does not establish a collaboration-management workflow.

The native app currently has no collaboration model, invite handling, or
per-contribution permission model. Ordinary playlist links retain navigation
identity and discard invitation parameters; opening one does not join.
Inspected sources do not establish complete membership, individual removal,
leave, or invitation-revocation readback. The request shapes expose no
compare-and-swap revision, leaving concurrent-write guarantees unverified.

## Implementation sequence

1. Add bounded read-only header metadata from the recognized collaboration
   renderer: at most 2 KiB of supplied plain text and 12 validated avatar sources.
   Preserve unknown state, account/profile fences, and existing paging and
   occurrence IDs. Labels and avatars must not grant edit authority.
2. Establish fresh target-specific role and per-occurrence permissions before
   enabling edits. Test owner, collaborator, viewer, withdrawn membership,
   duplicate songs, voting order, missing controls, and account changes with
   synthetic responses. Keep unavailable operations hidden or disabled.
3. Add separate default-off invite, join, and close-contribution capabilities
   only after authoritative readback is established. Review playlist, account,
   privacy, and destructive membership effects explicitly. Bound and validate
   invite URLs; keep invite tokens out of history, diagnostics, exports, and
   automatic sharing. Link opening must never silently join or autoplay.
4. Serialize scoped writes and retain uncertain outcomes. Never repeat invite
   creation, joining, closing, or item edits automatically after a lost response.
   Reconcile the exact target and membership before offering another attempt;
   profile replacement must wait for admitted work and its outcome bookkeeping.
5. Re-read before edits and after confirmed responses. If occurrence order,
   membership, privacy, or permissions changed, stop and request a refreshed
   review. Fresh reads cannot eliminate a later race; preserve other people's
   work and do not report atomic conflict protection without service evidence.

This audit introduces no native action or service call. Signed-in permissions,
invitation lifecycle, concurrent edits, keyboard access, and VoiceOver still
need runtime acceptance. Shared playlist editing supplies no synchronized
listening or shared playback-clock guarantee.
