# Source-preserving import support

The app now has a separate read-only archive view, original due-date display and
validated checklist state. The migration ledger is in a private, unexposed
database schema; exports, source files, account lists and credentials must never
be committed to this public repository.

## Verification

- Frontend: 192 tests; production build passes.
- Backend: 41 unit tests; production build passes.
- `npx tsx scripts/verify-import-foundations.ts` creates disposable accounts and
  cards in Development, then cleans them up. It verifies checklist save/undo,
  malformed checklist rejection, archive preservation during active moves, and
  the password gate across known-card edit-session and cleanup RPCs for both roles.
- `npx tsx scripts/verify-initial-password.ts` verifies initial password change,
  table/API denial, unforgeable completion stamps and old-session denial.
- Set `TEST_API_URL` to a hosted API URL to run either against the deployed server.

The legacy edit functions use SECURITY DEFINER; table RLS alone cannot enforce
the password gate inside them. Explicit actor/session checks are therefore
required before any card or edit-journal lookup. Regression tests exercise
existing card IDs and existing edit sessions, not only nonexistent IDs.

This document describes implemented import support, not a declaration that a
particular customer-data migration is complete. Its private reconciliation
ledger is authoritative for migration progress.
