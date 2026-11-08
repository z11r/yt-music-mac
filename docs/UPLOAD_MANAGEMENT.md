# Upload management feasibility

Native upload and upload-deletion controls are not implemented. Read-only
uploaded-music browsing is separate from transferring or deleting files.

Google documents a desktop web upload workflow for FLAC, M4A, MP3, OGG, and
WMA files, a 100,000-song library limit, and a restriction against uploads
to brand-account channels. Upload processing can continue before songs
appear in the library.
[Google's upload instructions](https://support.google.com/youtubemusic/answer/9716522?hl=en)
establish the supported user workflow.

The pinned
[ytmusicapi upload implementation](https://github.com/sigma67/ytmusicapi/blob/206d470bd857dde9e4c588170a23188037e03ad5/ytmusicapi/mixins/uploads.py)
provides a browser-authenticated, resumable request path: start a transfer on
`upload.youtube.com`, then send and finalize file bytes at the returned upload
URL. It also distinguishes upload deletion entity IDs from playback video
IDs. These source paths establish a prototype boundary; they have not been
verified in this app. No file is uploaded or deleted by the current client.

A native implementation needs the following checks before it can be enabled:

- Confirm the selected account and its upload restrictions before transfer.
- Validate files locally, show each transfer's byte progress, and bound resource use.
- Keep the upload session URL private and restrict its destination before sending credentials or file bytes.
- Fence account changes throughout transfer and completion reads.
- Handle cancellation during finalization as an uncertain outcome until service state is established.
- Separate transfer acceptance from completed library processing, and avoid blind retries that could submit another copy.
- Require an explicit destructive action for deletion using the exact upload entity ID, with service readback and no title-based cleanup.

The official web workflow remains the available management path. Native
transfer progress, cancellation recovery, deletion confirmation, and live
account verification remain incomplete.
