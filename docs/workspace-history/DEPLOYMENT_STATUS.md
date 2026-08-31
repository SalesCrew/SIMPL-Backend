> Historical workspace note copied before the Trello migration on 2026-08-31. Earlier deployment addresses and test counts below describe the time of that note; the current app is https://get-simpl.vercel.app.

# SIMPL deployment — verified 2026-08-31, 19:34 Europe/Vienna

## Deploy result

- **URL:** https://simpl-salescrew.vercel.app
- **Target:** production
- **Status:** READY
- **Commit:** `c4bc22553ea90b43ba1fcd43e1290516fad6228c`
- **Framework:** React / TypeScript / Vite
- **Build duration:** 10.6 seconds

Vercel project `trello-plus` was renamed to `simpl` in team `sales-crew`. Project ID: `prj_zczwpfHWvxTijqzSpj1xf05FKbjB`. Latest deployment: `dpl_YSYtMbZHupNmxmjs8WaXpW9xRYUW`, https://simpl-mk0djv7mg-sales-crew.vercel.app.

The new public address is a verified production domain, not a Vercel-login-protected preview alias. The previous https://trello-plus.vercel.app remains working and points to the same newest build. Preview deployment protection was retained. Both public addresses serve SIMPL branding and asset `/assets/index-CNurP1Cs.js`.

## Source repositories and automatic deployments

- Frontend: https://github.com/SalesCrew/SIMPL-Frontend — `main`, commit `c4bc225`.
- Backend: https://github.com/SalesCrew/SIMPL-Backend — `main`, commit `f3792f34ab549d2f1276eeea43bee3900ef3ac7f`.
- Local `frontend/` and `backend/` are separate Git repositories. Their HEADs match GitHub and both working trees are clean.
- Vercel and Railway are connected to the respective GitHub repositories and automatically deployed the latest pushes. Future pushes to `main` no longer require manual source uploads.
- No credentials, node_modules, build outputs or local QA manifests were committed.

## Railway backend and Supabase

- New private Railway project **SIMPL**: `c2426000-3925-4144-8298-45c831d58b1f`.
- Production environment: `9238b1a5-42d7-4cd1-867f-8c159e734c54`.
- Service **SIMPL-Backend**: `f8737835-22ae-4006-ae19-3a07a56dec36`.
- API: https://simpl-backend-production.up.railway.app.
- Active successful GitHub deployment: `ce32b905-bcb2-4510-a3c0-5a89699a3c3c`, backend commit `f3792f3`.
- Dashboard: https://railway.com/project/c2426000-3925-4144-8298-45c831d58b1f.
- Build `npm run build`, start `npm start`, health `/api/health`, timeout 120 seconds, On Failure / 5 retries, port 8080. Dashboard settings are used because new Railway services cannot opt into deprecated railway.json configuration.
- Existing Supabase project **Trello+**, `xqvexzoswhraqicbmckj`, SalesCrew / Frankfurt. Database, Auth, Realtime and private Storage remain there.
- Supabase URL, publishable key and server secret are configured privately on this Railway service after explicit user approval. No server secret is in the frontend.
- Health: HTTP 200, `ok: true`, `service: simpl-backend`, `configured: true`.
- New-domain CORS preflight: 204 with Authorization/Content-Type/Range support. Unrelated origin: 403. Anonymous file request: 401.

## File-access correction found during deployment

Live testing caught a Supabase CDN response surviving user deactivation, even with no-store uploads. Fresh requests were denied, but a previously authorized URL could return cached bytes. Frontend cache changes alone were insufficient.

Downloads now use `GET /api/attachments/:id/download`. Each request checks the current login, active profile and live attachment RLS before streaming server-only Storage bytes. Responses use private/no-store headers; large files stream with backpressure and support single byte ranges. Direct client Storage SELECT, including metadata/HEAD paths used by CDN authorization, is denied. Uploads retain reservation-scoped INSERT RLS. Already saved copies cannot be recalled.

Security migrations are versioned in the backend repository. No production data was reset. [Supabase CDN documentation](https://supabase.com/docs/guides/storage/cdn/fundamentals) describes the platform caching model.

## Verification completed

- **152 frontend tests and 39 backend tests passed**; both production builds passed.
- Live Railway integration: login, provisioning, member/admin authorization, card completion/restoration, concurrent updates, labels, comments, notifications, Realtime and access revocation.
- Live card/comment file lifecycles: PNG, PDF, Excel, arbitrary binaries, private drafts, atomic messages, limits, forged paths, invalid bytes/size, cleanup, signed-link/direct-read denial and old-token revocation on previously downloaded URLs.
- **Actual 500 MB TUS upload**, network/lost-acknowledgement recovery, hosted finalization, authenticated ranged download through Railway and atomic comment publication. 500 MB + 1 byte rejected. Download verification reads a byte range, not another full 500 MB transfer.
- Live workspace isolation: symmetric blocks, full isolation, no shared-workspace bridging, metadata/RPC/API/file denial, existing-token revocation and admin override.
- Chrome on the public SIMPL domain: login/live board, custom dropdown, completion and return to SPARK, card/message image zoom, screenshot copy, real download matching fixture bytes, image paste into comments, Shift+Enter newline, Enter send and visible composer. Database inspection confirmed the browser-uploaded image was published to its comment.
- Latest public bundle contains the Railway endpoint and correct Supabase project, without a server-secret prefix.
- Disposable verification cards, files, accounts and four isolated test workspaces were removed. The fixed-column validator remains enabled. Eight existing Railway projects were not modified.

## Post-deploy observability and optional hardening

- **Error scan:** no error logs returned for the latest Vercel deployment (`--level error --since 1h`). This is a point-in-time check, not ongoing monitoring.
- **Drains:** 0 configured. No monitoring automation was created.
- **Supabase advisor:** no database/RLS warnings; one existing Auth warning remains: leaked-password protection is disabled. This optional account-security setting was not silently changed. [Remediation](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection).

## Scope preserved

No database reset was performed. A clean-start reset remains reserved for the user's later explicit request. No existing Railway production project was changed or deleted.
