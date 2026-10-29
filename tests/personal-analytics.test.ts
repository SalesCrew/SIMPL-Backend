import { beforeEach, describe, expect, it, vi } from "vitest";
import request from "supertest";
const OWNER = "e68b62cd-06b3-4300-8a16-dc04e20ed75d";
const WORKSPACE = "2bb0db3c-9ec4-4066-8f58-0a7712fb6325";
const mocks = vi.hoisted(() => ({ id: "", active: true, ready: true, role: "admin", invalid: false, calls: [] as { table: string; filters: [string, unknown][]; projection?: string }[], cards: [] as Record<string, unknown>[], missingWorkspace: false, failure: false }));
vi.mock("@supabase/supabase-js", () => ({ createClient: (_url: string, _key: string, options?: { global?: unknown }) => options?.global ? {
  auth: { getUser: async () => ({ data: { user: mocks.invalid ? null : { id: mocks.id } }, error: mocks.invalid ? { message: "invalid" } : null }) },
  rpc: async () => ({ data: { ready: mocks.ready }, error: null }),
  from: (table: string) => {
    const call = { table, filters: [] as [string, unknown][], projection: "" }; mocks.calls.push(call);
    let after = "", limit = 1000;
    const result = () => ({ data: table === "workspaces" ? (mocks.missingWorkspace ? null : { id: "2bb0db3c-9ec4-4066-8f58-0a7712fb6325", name: "Development" }) : table === "columns" ? [{ id: "project", name: "Projekt A" }] : table === "labels" ? [{ id: "bug", name: "Bug" }] : mocks.cards.filter(c => String(c.id) > after).slice(0, limit), error: mocks.failure ? { code: "private-db-error", message: "sensitive schema detail" } : null });
    const chain = { select: (fields: string) => { call.projection = fields; return chain; }, eq: (key: string, val: unknown) => { call.filters.push([key, val]); return chain; }, is: (key: string, val: unknown) => { call.filters.push([key, val]); return chain; }, order: () => chain, limit: (n: number) => { limit = n; return chain; }, gt: (_key: string, val: string) => { after = val; return chain; }, maybeSingle: async () => result(), then: (resolve: (r: unknown) => unknown) => Promise.resolve(result()).then(resolve) };
    return chain;
  },
} : { from: () => ({ select: () => ({ eq: () => ({ single: async () => ({ data: { id: mocks.id, active: mocks.active, role: mocks.role }, error: null }) }) }) }) } }));
import app from "../server.js";
import { personalAnalyticsPayload } from "../src/personal-analytics.js";
const card = (id: string, done: string | null = "2026-10-25T10:00:00Z") => ({ id, title: "Synthetic task", created_at: "2026-10-20T10:00:00Z", completed_at: done, archived_at: null as string | null, deleted_at: null as string | null, project_id: "project", label_ids: ["bug"] });
beforeEach(() => {
  vi.stubEnv("SUPABASE_URL", "https://example.invalid"); vi.stubEnv("SUPABASE_PUBLISHABLE_KEY", "test-public"); vi.stubEnv("SUPABASE_SECRET_KEY", "test-server");
  Object.assign(mocks, { id: OWNER, active: true, ready: true, role: "admin", invalid: false, calls: [], cards: [card("1"), card("2", null)], missingWorkspace: false, failure: false });
});
describe("private personal analytics boundary", () => {
  it.each(["/api/personal-analytics", "/api/personal-analytics/access"])("requires a verified active ready owner: %s", async path => {
    expect((await request(app).get(path)).status).toBe(401);
    mocks.invalid = true; expect((await request(app).get(path).set("Authorization", "Bearer invalid")).status).toBe(401);
    mocks.invalid = false; mocks.active = false; expect((await request(app).get(path).set("Authorization", "Bearer owner")).status).toBe(403);
    mocks.active = true; mocks.ready = false; expect((await request(app).get(path).set("Authorization", "Bearer owner")).status).toBe(403);
    expect(mocks.calls).toHaveLength(0);
  });
  it.each(["admin", "mitarbeiter"])("returns a generic 404 for a different %s before reading any business data", async role => {
    mocks.id = "00000000-0000-4000-8000-000000000001"; mocks.role = role;
    for (const path of ["/api/personal-analytics", "/api/personal-analytics/access", `/api/personal-analytics?actor_id=${OWNER}`]) {
      const result = await request(app).get(path).set("Authorization", "Bearer other").set("X-Actor-Id", OWNER);
      expect(result.status).toBe(404); expect(result.body).toEqual({ error: "Nicht gefunden." }); expect(result.text).not.toContain("Kilian"); expect(result.headers["cache-control"]).toContain("no-store");
    }
    expect(mocks.calls).toHaveLength(0);
  });
  it("grants only the verified owner and uses his RLS-scoped client for all data", async () => {
    const access = await request(app).get("/api/personal-analytics/access").set("Authorization", "Bearer owner"); expect(access.body).toEqual({ allowed: true }); expect(mocks.calls).toHaveLength(0);
    const result = await request(app).get("/api/personal-analytics").set("Authorization", "Bearer owner");
    expect(result.status).toBe(200); expect(result.body.flow_tasks).toHaveLength(2); expect(result.body.tasks).toHaveLength(1); expect(result.body.meta.open_cards).toBe(1); expect(result.body.tasks[0].project).toBe("Projekt A"); expect(result.body.tasks[0].labels).toEqual(["Bug"]);
    for (const call of mocks.calls) expect(call.filters).toContainEqual([call.table === "workspaces" ? "id" : "workspace_id", WORKSPACE]);
    const cards = mocks.calls.find(c => c.table === "cards")!; expect(cards.filters).toContainEqual(["deleted_at", null]); expect(cards.projection).not.toMatch(/description|assignee|comments|\*/);
    expect(result.headers.vary).toContain("Authorization"); expect(result.headers["cache-control"]).toBe("private, no-store, max-age=0");
  });
  it("rejects client-selected identities/workspaces and unsupported routes", async () => {
    for (const query of ["workspace_id=another", `actor_id=${OWNER}`, "limit=1"]) expect((await request(app).get(`/api/personal-analytics?${query}`).set("Authorization", "Bearer owner")).status).toBe(400);
    expect(mocks.calls).toHaveLength(0);
    expect((await request(app).post("/api/personal-analytics").set("Authorization", "Bearer owner").send({ owner_id: OWNER })).status).toBe(404);
  });
  it("loads every page without a silent 1000-card truncation", async () => {
    mocks.cards = Array.from({ length: 1003 }, (_, i) => card(String(i).padStart(8, "0")));
    const response = await request(app).get("/api/personal-analytics").set("Authorization", "Bearer owner"); expect(response.status).toBe(200); expect(response.body.tasks).toHaveLength(1003); expect(mocks.calls.filter(c => c.table === "cards")).toHaveLength(3);
  });
  it("does not reveal revoked workspace data or database internals", async () => {
    mocks.missingWorkspace = true; expect((await request(app).get("/api/personal-analytics").set("Authorization", "Bearer owner")).status).toBe(404); expect(mocks.calls.map(c => c.table)).toEqual(["workspaces"]);
    mocks.missingWorkspace = false; mocks.failure = true; const result = await request(app).get("/api/personal-analytics").set("Authorization", "Bearer owner"); expect(result.status).toBe(500); expect(result.text).not.toContain("sensitive schema");
  });
});
describe("data contract without embedded private snapshots", () => {
  it("keeps archived completions once, open arrivals and labelled archive fallbacks", () => {
    const archived = { ...card("1"), archived_at: "2026-10-27T12:00:00Z" }, fallback = { ...card("2", null), archived_at: "2026-10-28T12:00:00Z" }, open = card("3", null), deleted = { ...card("4"), deleted_at: "2026-10-28T12:00:00Z" };
    const payload = personalAnalyticsPayload([archived, fallback, open, deleted], [{ id: "project", name: "A" }], [{ id: "bug", name: "Bug" }], new Date("2026-10-29T12:00:00Z"), "Development");
    expect(payload.tasks).toHaveLength(2); expect(payload.flow_tasks).toHaveLength(3); expect(payload.tasks[0].completed_at).toBe(archived.completed_at); expect(payload.tasks[1].completion_source).toBe("archive-fallback"); expect(payload.tasks[1].original_completed_at).toBeNull(); expect(payload.meta.archive_fallback_cards).toBe(1); expect(payload.meta.snapshot_vienna).toBe("2026-10-29 13:00"); expect(payload.coverage.start_date).toBe("2026-10-20");
  });
  it("has a valid empty-state date and retains broken timestamps for explicit audits", () => {
    const date = new Date("2026-10-29T12:00:00Z"); const empty = personalAnalyticsPayload([], [], [], date, "Development"); expect(empty.tasks).toEqual([]); expect(empty.meta.first_date).toBe("2026-10-29");
    const broken = personalAnalyticsPayload([{ ...card("broken"), created_at: "invalid" }], [], [], date, "Development"); expect(broken.tasks[0].duration_hours).toBeNull(); expect(broken.tasks[0].project).toBe("Ohne Projekt");
  });
});
