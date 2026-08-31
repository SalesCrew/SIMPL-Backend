> Historical workspace note copied before the Trello migration on 2026-08-31. Earlier deployment addresses and test counts below describe the time of that note; the current app is https://get-simpl.vercel.app.

# Card attachments: UI and behavior

## Placement and interaction

- Keep the existing description/comments split. Add a quiet attachment section below the description, with a dashed dropzone and compact file picker.
- Save a new card first, then open its detail view so attachments always have a real card identity.
- Accept drag-and-drop, file selection and image/file paste while the detail dialog is open. Plain pasted text continues to work in inputs.
- Show screenshots as thumbnails, documents as filename/type/size tiles. Every file can be downloaded; raster images have a larger preview and a Copy image action.
- Show actual upload progress, success/error feedback and retry/cancel controls. Disable closing/deleting the card while its upload is active. Respect reduced-motion preferences.
- Current limits: 500 MB per file, 20 direct card attachments, 10 attachments per comment. Files over 6 MB use resumable 6-MB chunks. Any file format can be shared; only PNG/JPEG/WebP/GIF up to 20 MB receive inline image previews. Other formats and larger files are download tiles. Unknown/active formats and files over 20 MB use application/octet-stream, never embedded HTML/SVG/script. Files are not claimed to be antivirus-scanned. Upload reservations last 24 hours.

## Comment integration

- A paperclip, drop target and paste handler live inside the pinned comment composer. Selected files remain local until Send, with removable thumbnail/name tiles and a bounded scroll area. Enter sends, Shift+Enter adds a line; files without text are valid.
- Uploads are marked with a private draft ID. Sending a comment validates and links all its file IDs atomically, preventing foreign-owner/cross-card/duplicate/expired links. A failed send keeps its draft for retry.
- Comment galleries show images before text, with All / Images / Files tabs for multiple attachments. Image tiles reuse the card lightbox, clipboard conversion and authenticated download implementation; no second viewer or third-party document service.
- Comment deletion/undo retires attachment metadata for Storage API cleanup. Expired ready drafts are included in cleanup; draft cancellation cannot delete a concurrently published attachment. Workspace RLS applies to both metadata and file reads.

## Storage and protection

- One private Supabase bucket, immutable random object paths, attachment metadata attached to an existing card. Never expose service credentials or public/signed download links.
- Only active provisioned members may upload/download; visibility follows the existing shared-workspace model. Metadata writes and finalization go through the authenticated backend. Storage RLS permits uploads only to the caller's live reservation, and reads only for published files (or the caller's pending upload).
- Validate names, allowed extensions/types and sizes on both sides, check stored bytes before publication, limit reservation counts under a row lock, and disallow object overwrites.
- Track pending/ready/deleting state. Remove objects through Storage's API, never by deleting storage SQL rows. Keep metadata if cleanup fails, so cleanup can be retried. Expired reservations are swept before further uploads and by an operator cleanup command.
- Card deletion cleans its files first; a restrictive foreign key blocks database deletion that would bypass cleanup. Concurrent reservations can make deletion safely retry instead of orphaning a file.
- The local demo stores file blobs in IndexedDB and only metadata in the existing local board cache.

## Verification

- Unit tests for allowed types, signatures, limits and lifecycle rules.
- Disposable live accounts/files: upload, publish, authenticated read, anonymous/unprovisioned/deactivated denial, forged reservation/metadata denial, overwrite denial, cancellation, deletion and card cleanup.
- Browser checks for previews, errors, drag/paste/file-input paths where supported, clipboard copying, downloads and clean visual states. Report any browser-control verification limits rather than claiming unperformed checks.
