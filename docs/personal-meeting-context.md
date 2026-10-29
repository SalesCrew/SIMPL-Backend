# Private meeting context v1

SalesCrew SIMPL (`xqvexzoswhraqicbmckj`), Development, exact existing personal-analytics owner only. Other administrators do not inherit access. The existing authenticated active-profile/password/session gate applies before any meeting endpoint, in addition to forced database RLS. No auth credentials or full meeting sources belong in this repository.

The authoritative Draft 7 schema is `src/meeting-context/contract-v1.schema.json`, version `salescrew.meeting.v1`, canonical SHA-256 `f2bd9dce887063926dd71ff84bdebf03b143bb6b23d1d34f2c00c93bcd851ef1`. A byte-identical local handoff and the operational writer workflow are maintained in the owner's `JF mit Philipp/meeting-sync` directory.

## Label scope

Primary labels are SPARK/Coke, ROVER/Mars, Compass/Samsung, OBI, Nespresso and SIMPL. IDs reference existing Development labels; names and colours are resolved live. GM/SM are optional Coke subcategories. Every project-meeting section requires its primary label in `label_ids`; `project_id` is only an existing internal integrity anchor. Card references require actual matching primary-label membership, independent of their column. JF has one section, null label/project, no inferred tags. No board entities are created or relabelled.

## Operations

All `/api/personal-analytics/meetings` responses are private, no-store and owner gated:

- `GET /contract`: require ready and exact live schema hash.
- `GET /?after=<uuid>`: bounded keyset pagination, compact marker data only.
- `GET /<meeting>?label_id=<uuid>`: selected-label detail only.
- `GET /<meeting>/protocol/<section>?label_id=<uuid>`: one full Markdown section, fetched on demand.
- `POST /sync`: schema/hash/size/content-scope preflight, then owner-session RPC. Only this route permits a 1 MiB body; ordinary API routes keep 16 KiB.

The separate explicitly authorized Codex writer uses postgres-only readiness/state/batch functions in `private`, without impersonating a JWT. Identity/access and every existing label/project/card/comparison reference are revalidated by the writer. Client direct writes are revoked, including for service_role; normal authenticated SELECT is controlled by exact-owner fresh-session RLS. Upserts preserve identity and revision history, reject stale different writes, and keep identical retries unchanged. Batch dry-run rolls back every tentative write and refresh-counter change. Older imports flag affected later comparisons for review. No workspace notifications are emitted.

Semantic SalesCrew scope review and local rejection are required before preparing any SQL, including dry-run. S-Academy/SAK content, mixed unreviewed content and uncertain identity stay local. API and DB guards repeat technical exclusions. This is a bounded owner workflow, not a general privileged portal.

Only proven held meetings enter the inventory. Original Vienna meeting dates, note dates, follow-ups and sync timestamps stay distinct; unknown dates remain null. Original individual Markdown is preserved; central histories, agendas and implementation files are not additional meetings. Arrays and exact-byte source fingerprints retain order/bytes. Hashing excludes only `content_hash`, `exported_at`, `revision`, `base_revision` from recursively sorted compact JSON.

## Verification

Contract/API tests cover exact owner vs another administrator, revoked/inactive/unready access, reference scope, compact vs lazy full reads, size limits, version/hash, exclusion before RPC, revision semantics and byte preservation. Live PostgreSQL verification covers forced RLS/grants, real reviewed import, zero-persistence dry-run, unchanged retries, rollback-only stale/reference-conflict cases, and schema/Markdown hashes. Controlled browser fixtures verify marker grouping, JF/no-data/undated handling, safe Markdown, label isolation, mobile layouts, account switching and unchanged task/overlay/moving-average state. Production owner UI requires the owner's existing signed-in session; tests do not extract or impersonate it.
