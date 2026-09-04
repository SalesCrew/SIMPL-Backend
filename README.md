# SIMPL Backend

Express + TypeScript API. Production hosting: Railway. Database, Auth, Realtime, and private file storage: the existing Supabase `Trello+` project.

## Development and checks

Use Node.js 22 or newer. Run `npm ci`, copy `.env.example` to `.env`, configure it, then `npm run dev`.

`npm test` runs unit tests. `npm run build` type-checks and compiles the production server. `npm start` serves that build on `0.0.0.0:$PORT` (default 3001).

## Railway

Create a separate project from `SalesCrew/SIMPL-Backend`. In Railway service settings use Railpack, build command `npm run build`, start command `npm start`, health check `/api/health`, and the On Failure restart policy. Configure these in the service dashboard: new services can no longer opt into the deprecated `railway.json` configuration format.

Set `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_SECRET_KEY`, and `FRONTEND_ORIGINS` as Railway service variables. `FRONTEND_ORIGINS` is a comma-separated exact allowlist of frontend origins. Set `PORT=8080` and use the same target port for the public domain. The SMTP variables needed for workspace email are documented in `docs/EMAIL_NOTIFICATIONS.md`.

Keep `SUPABASE_SECRET_KEY` server-only. It must never appear in Git, frontend variables, logs, or client bundles. No database migration or data reset runs during build/start/deploy.

Supabase migrations are versioned in `supabase/migrations/`. They have already been applied to the existing project; do not reapply historical migrations or reset production to deploy this API.

Card acknowledgement (`reviewed_at` / `reviewed_by`, shown as “Von [Name] gelesen”) is shared state. Every active role with workspace access can toggle it via direct card updates or edit sessions. The database supplies the actor and timestamp; workspace restrictions and session ownership remain enforced.

## Workspace activity notifications

The yellow bell is a private workspace activity feed. Authenticated user actions create notifications for every other active profile that can access the affected workspace: cards created, edited, moved, completed, reopened, acknowledged, archived/restored or deleted; card files added or removed; and new comments. The actor never receives their own event. Comment attachments are represented by the comment event so one message produces one bell entry.

Every active member with access to a workspace can archive one of its cards from the detailed card view. The protected card edit session sets `archived_at`, records the change for the five-second undo receipt and lets the existing activity trigger notify the other workspace members. Archived cards leave all active board queries immediately and remain read-only in the archive.

`private.publish_workspace_notification` is the only fan-out writer. It resolves recipients from live workspace/NDA rules, while notification RLS independently requires both `recipient_id = auth.uid()` and current access to `workspace_id`. Compound card operations share a transaction event key and collapse into one entry. Drag rebalancing marks only the actual dragged card, not every sibling whose numeric position changes. Five-second card undo deletes activity created by that edit session, so a reverted action cannot leave a false alert. Realtime continues through the per-user `access_revisions` channel; notification rows themselves do not expose another member's feed.

## Workspace email notifications

New cards, comments, card acknowledgements, completed cards and archived cards also create one email job for every other active profile with current access to the workspace. The existing private workspace notification writer remains the sole recipient authority, so actor exclusion and NDA isolation are identical for the bell and email. Each successful action calls the authenticated Railway dispatch API, which claims jobs with short leases and sends each recipient separately through the configured EWS/NTLM-over-HTTPS or TLS SMTP transport. There is no repeating mail poller. Failed deliveries use event-tied backoff retries; a browser disconnect cannot remove a committed job. See `docs/EMAIL_NOTIFICATIONS.md` for configuration and operations.

## Mandatory initial password change

Every new profile receives an `account_security` row requiring a password change. `account_access_context()` exposes only the caller's gate status before workspace loading. Clients cannot forge the completion stamp. Restrictive RLS gates all business tables, and the API checks the same access context, including for admins. Existing workspace isolation policies are preserved.

`POST /api/account/initial-password` validates two matching 12–128-character passwords, changes the authenticated user's password through Supabase Auth, revokes old sessions, and records completion through a service-only operation. A short per-account lease prevents concurrent completion requests. Only a new Auth session created after the database timestamp can access data, so still-valid old JWTs remain blocked. Admin-set passwords re-enable this requirement.

Run `npx tsx scripts/verify-initial-password.ts` to test both roles against Supabase using disposable accounts and the local Express app. Set `TEST_API_URL` to test the hosted API instead. This verifies pre-change RLS/API denial, unforgeable stamps, unchanged-password rejection, post-change access, old-token denial and reset behavior. Legacy hand-written SQL fixtures must model completed password setup and a real Auth session before expecting business access.

## Live verification

### Immediate card moves

`POST /api/cards/:id/move` accepts `{ column_id, before_id? }` after account/password validation. It uses the caller's JWT with `move_card_with_receipt`, an invoker-rights wrapper around the existing atomic move RPC. The same transaction returns every rebalanced destination card, including revisions and return-location metadata. Workspace RLS, archive locks, completion rules and original project identity are unchanged.

The frontend renders an optimistic position immediately, without a global loading state, and merges the receipt instead of awaiting a full board reload. Polling cannot overwrite pending positions; failed requests remove only their own overlay and reconcile with the server. A second drag of the same card is briefly disabled until its first save settles; other cards stay interactive. Later edits/completion wait for that move so their snapshots preserve ordering.

The tiny move request uses browser `keepalive`. Once the server receives/authenticates it, its database operation is independent of client disconnects. This is not an offline queue or a promise to survive server/process failure: a request that never reaches the server cannot be saved. Do not automatically retry ambiguous network failures, which could reorder newer moves.

`npx tsx scripts/verify-card-moves.ts` exercises the real API/database using disposable projects, cards and an account, then removes them. `TEST_API_URL` targets production. Unit tests also disconnect a real HTTP socket while the database operation is pending and verify that it finishes.

Set `TEST_API_URL` to the API origin for `npm run test:integration`, or `TEST_ATTACHMENT_API_URL` for `npm run test:attachments`. These create and remove only temporary verification fixtures. Other verification scripts are in `scripts/` and transactional SQL checks in `sql/`.

The companion UI is [SIMPL-Frontend](https://github.com/SalesCrew/SIMPL-Frontend), live at https://get-simpl.vercel.app. The API is https://simpl-backend-production.up.railway.app. Both deploy from their GitHub `main` branch.

Board data uses authenticated Supabase/RLS. File downloads use `GET /api/attachments/:id/download`: each request verifies the login, active profile and live attachment RLS before streaming server-only Storage bytes. Responses disable caching and support single byte ranges without buffering 500 MB in the API. Clients have no Storage SELECT permission (including metadata/HEAD, which the CDN can use to authorize byte responses). Uploads still go directly to Storage through reservation-scoped INSERT RLS. Do not restore direct client downloads or signed links: CDN authorization can outlive workspace/profile changes. Previously saved copies cannot be recalled.
