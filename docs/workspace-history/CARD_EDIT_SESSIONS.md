> Historical workspace note copied before the Trello migration on 2026-08-31. Earlier deployment addresses and test counts below describe the time of that note; the current app is https://get-simpl.vercel.app.

# Card edit sessions

- Opening an existing card creates an authenticated, server-timestamped snapshot before edits are accepted. New cards are created normally, then start a session.
- Title and description have independent explicit save buttons. Unsaved text is discarded on close. Dropdowns, labels, status, comments and uploads save immediately.
- Closing is synchronous UI work. The session controller survives the dialog and drains queued saves/uploads before finalizing the undo offer.
- The compact toast rises from the bottom-center of the entire viewport and lasts five seconds. Expanding it (or keyboard focus/hover) pauses dismissal; a renewable server lease keeps it undoable. The server deadline is seven seconds, allowing a small transport grace period. A database sweep removes expired snapshots even if the browser disappears.
- Collapsing the details explicitly starts a fresh five-second countdown, even while the collapse button retains focus or the pointer remains over the toast. A new hover/focus interaction can pause it again.
- Timeout, the close button and completed undo all slide the toast down out of the viewport over 250 ms before removing it. Cleanup stays in the background, interaction stops during exit, and reduced-motion preferences skip the animation.
- Undo is atomic and includes saved text, metadata, comments and attachment additions/removals. Card deletion is temporarily soft, so it can also be undone. Files removed during a session are inaccessible but retained until the offer expires. Existing attachment cleanup handles physical object removal after retention ends.
- Every write to the card or its comments/attachments advances a server-controlled revision. An intervening write by another session makes undo fail safely; it never restores a stale snapshot over someone else's work.
- Snapshot/journal tables live in the private schema, have RLS and no client table grants. Fixed-purpose RPCs check the current authenticated owner and live workspace access for every operation. Upload finalization remains service-only after byte validation.
- No-op sessions create no toast. A session is bounded to 200 journal entries and 10 concurrent sessions per person. Abandoned open sessions expire after 15 minutes without a heartbeat.

Verification must cover ownership, revoked access, malicious action/card IDs, upload finalization, conflicts, expiration, pending work at close, saved/unsaved text, and instant dismissal.

## Verification completed

- `frontend/src/card-edit-session.test.ts`: controller ordering, background uploads, instant close, no-op sessions, failure handling, whole-session restore, deletion and conflicts.
- `frontend/src/components/card-editing-ui.test.tsx`: per-field explicit save controls, clean new-card form, accessible compact undo controls.
- `backend/sql/verify-card-edit-sessions.sql`: real PostgreSQL tests inside a rolled-back transaction; snapshots, owner checks, revoked access, cross-card rejection, service-only finalization, comments/notifications, attachment retention, deletion, exact restore, ABA conflicts, expiry and RLS passed.
- `backend/scripts/verify-card-edit-sessions.ts`: real authenticated API/Storage round trip passed, including byte validation, access denial while removed, held-file protection, exact byte restoration and physical deletion of an undone upload. The test's empty workspace needed owner cleanup because fixed buckets cannot be deleted through client APIs; that cleanup was completed in the retention-hardening migration. Future runs report their unique empty workspace ID for the same guarded owner cleanup.
- Browser: independent save/loading/one-second feedback, metadata autosave without saving description drafts, immediate X/outside close while a save was pending, exact expanded diffs, persistent expanded toast, complete undo and 390px layout checked. The toast is centered in the full viewport on desktop/mobile. The five-second timeout is followed by a measured 250 ms downward exit; expanded manual dismissal also animates without waiting for background cleanup.
- Supabase expiry job is active and succeeding. Security advisors returned no findings after the explicit private-table deny policy.

### Operational notes

Frontend/API source changes are local; the session, cleanup, retention-hardening and comment-diff database migrations are applied to the configured Supabase project. Publish frontend and API together when deploying. The existing attachment cleanup script also sweeps expired retained files and deleted cards; normal resolved offers trigger the scoped cleanup endpoint immediately. If a browser disappears before resolution, snapshot expiry is automatic, while abandoned Storage bytes are handled by the existing cleanup sweep or the next upload on that card.

The parallel comment-attachment work is compatible: sent message files appear in the exact diff and are removed by undo, including attachment-only messages. This was verified in the rolled-back PostgreSQL test. Lease updates are ordered per session; expanding cannot be overtaken by an earlier collapsed offer request.
