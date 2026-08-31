# SIMPL Backend

Express + TypeScript API. Production hosting: Railway. Database, Auth, Realtime, and private file storage: the existing Supabase `Trello+` project.

## Development and checks

Use Node.js 22 or newer. Run `npm ci`, copy `.env.example` to `.env`, configure it, then `npm run dev`.

`npm test` runs unit tests. `npm run build` type-checks and compiles the production server. `npm start` serves that build on `0.0.0.0:$PORT` (default 3001).

## Railway

Create a separate project from `SalesCrew/SIMPL-Backend`. In Railway service settings use Railpack, build command `npm run build`, start command `npm start`, health check `/api/health`, and the On Failure restart policy. Configure these in the service dashboard: new services can no longer opt into the deprecated `railway.json` configuration format.

Set `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_SECRET_KEY`, and `FRONTEND_ORIGINS` as Railway service variables. `FRONTEND_ORIGINS` is a comma-separated exact allowlist of frontend origins. Set `PORT=8080` and use the same target port for the public domain.

Keep `SUPABASE_SECRET_KEY` server-only. It must never appear in Git, frontend variables, logs, or client bundles. No database migration or data reset runs during build/start/deploy.

Supabase migrations are versioned in `supabase/migrations/`. They have already been applied to the existing project; do not reapply historical migrations or reset production to deploy this API.

Card acknowledgement (`reviewed_at` / `reviewed_by`, shown as “Von [Name] gelesen”) is shared state. Every active role with workspace access can toggle it via direct card updates or edit sessions. The database supplies the actor and timestamp; workspace restrictions and session ownership remain enforced.

## Mandatory initial password change

Every new profile receives an `account_security` row requiring a password change. `account_access_context()` exposes only the caller's gate status before workspace loading. Clients cannot forge the completion stamp. Restrictive RLS gates all business tables, and the API checks the same access context, including for admins. Existing workspace isolation policies are preserved.

`POST /api/account/initial-password` validates two matching 12–128-character passwords, changes the authenticated user's password through Supabase Auth, revokes old sessions, and records completion through a service-only operation. A short per-account lease prevents concurrent completion requests. Only a new Auth session created after the database timestamp can access data, so still-valid old JWTs remain blocked. Admin-set passwords re-enable this requirement.

Run `npx tsx scripts/verify-initial-password.ts` to test both roles against Supabase using disposable accounts and the local Express app. Set `TEST_API_URL` to test the hosted API instead. This verifies pre-change RLS/API denial, unforgeable stamps, unchanged-password rejection, post-change access, old-token denial and reset behavior. Legacy hand-written SQL fixtures must model completed password setup and a real Auth session before expecting business access.

## Live verification

Set `TEST_API_URL` to the API origin for `npm run test:integration`, or `TEST_ATTACHMENT_API_URL` for `npm run test:attachments`. These create and remove only temporary verification fixtures. Other verification scripts are in `scripts/` and transactional SQL checks in `sql/`.

The companion UI is [SIMPL-Frontend](https://github.com/SalesCrew/SIMPL-Frontend), live at https://get-simpl.vercel.app. The API is https://simpl-backend-production.up.railway.app. Both deploy from their GitHub `main` branch.

Board data uses authenticated Supabase/RLS. File downloads use `GET /api/attachments/:id/download`: each request verifies the login, active profile and live attachment RLS before streaming server-only Storage bytes. Responses disable caching and support single byte ranges without buffering 500 MB in the API. Clients have no Storage SELECT permission (including metadata/HEAD, which the CDN can use to authorize byte responses). Uploads still go directly to Storage through reservation-scoped INSERT RLS. Do not restore direct client downloads or signed links: CDN authorization can outlive workspace/profile changes. Previously saved copies cannot be recalled.
