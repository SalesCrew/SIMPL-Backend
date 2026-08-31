> Historical workspace note copied before the Trello migration on 2026-08-31. Earlier deployment addresses and test counts below describe the time of that note; the current app is https://get-simpl.vercel.app.

# Card return location — 2026-08-31

- Applied `20260831164248_card_return_location.sql` to Supabase project `Trello+` (`xqvexzoswhraqicbmckj`). Existing completion RPC callers use the new behavior immediately; no frontend deployment was performed.
- Leaving a project remembers its column, next/previous card and index. Movement within or between In Arbeit/Fertig preserves that memory. Reopening goes to that project slot, not necessarily the creation project. Moving into another project starts a new origin for the next trip.
- The database trigger manages these fields independently of frontend input. Return columns are constrained to the same workspace; completion stays SECURITY INVOKER with the existing RLS. Undo restores the private session's original return metadata.
- If the next neighbor has moved/deleted, use the previous neighbor; if both are unavailable, use the saved index. Previously completed cards without historical metadata fall back to the end of the creation project. No historical order was invented or user card data backfilled.

## Passed

- 149 frontend tests, including ten new first/middle/last slot, In Arbeit, last-project, reordered/deleted neighbor, repeated-check, undo and legacy-cache cases.
- 35 backend unit tests; frontend and backend builds.
- Transactional real-database verification in `backend/sql/verify-card-return-location.sql`: exact visible order, project rebalancing, latest project, client forgery rejection, undo and isolated-workspace denial.
- Existing full card-edit-session SQL regression: complete snapshot restoration, files/comments, deletion, ownership, expiry, conflicts and RLS.
- Existing API/Supabase integration: login, shared cards, concurrent/idempotent completion, last-project return, comments, Realtime and access revocation.
- Security advisor: no findings. Performance advisor reports informational unused indexes, including the new FK-supporting index; these are retained for real usage ([advisor explanation](https://supabase.com/docs/guides/database/database-linter?lint=0005_unused_index)).

All transactional fixtures were rolled back; the API integration removed only its generated cards, labels and accounts. A follow-up query confirmed zero remaining return-location/undo fixture workspaces.
