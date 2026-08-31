import { beforeEach, describe, expect, it, vi } from "vitest";
import request from "supertest";
import { request as httpRequest } from "node:http";
import { once } from "node:events";
import type { AddressInfo } from "node:net";

const mocks = vi.hoisted(() => ({ move: vi.fn(), ready: true, active: true, authenticated: true, adminRpc: vi.fn() }));
vi.mock("@supabase/supabase-js", () => ({
  createClient: (_url: string, _key: string, options?: { global?: unknown }) => options?.global ? {
    auth: { getUser: async () => ({ data: { user: mocks.authenticated ? { id: "caller" } : null }, error: null }) },
    rpc: (name: string, args: unknown) => name === "account_access_context"
      ? Promise.resolve({ data: { ready: mocks.ready }, error: null }) : mocks.move(name, args),
  } : {
    from: () => ({ select: () => ({ eq: () => ({ single: async () => ({ data: { active: mocks.active, role: "mitarbeiter" }, error: null }) }) }) }),
    rpc: mocks.adminRpc,
  },
}));
import app from "../server.js";

const card = "00000000-0000-4000-8000-000000000001";
const column = "00000000-0000-4000-8000-000000000002";
const endpoint = `/api/cards/${card}/move`;
beforeEach(() => {
  vi.stubEnv("SUPABASE_URL", "https://example.invalid");
  vi.stubEnv("SUPABASE_PUBLISHABLE_KEY", "test-key");
  vi.stubEnv("SUPABASE_SECRET_KEY", "test-server-key");
  mocks.ready = mocks.active = mocks.authenticated = true;
  mocks.move.mockReset().mockResolvedValue({ data: [{ id: card, column_id: column }], error: null });
  mocks.adminRpc.mockReset();
});

describe("server-owned card moves", () => {
  it("uses the member JWT and returns the atomic receipt", async () => {
    const result = await request(app).post(endpoint).set("Authorization", "Bearer test-session").send({ column_id: column });
    expect(result.status).toBe(200);
    expect(result.body.cards).toEqual([{ id: card, column_id: column }]);
    expect(mocks.move).toHaveBeenCalledExactlyOnceWith("move_card_with_receipt", { p_card: card, p_column: column, p_before: null });
    expect(mocks.adminRpc).not.toHaveBeenCalled();
    expect(result.headers["cache-control"]).toBe("no-store");
  });
  it("denies missing/expired sessions, inactive users and unchanged initial passwords before moving", async () => {
    expect((await request(app).post(endpoint).send({ column_id: column })).status).toBe(401);
    mocks.authenticated = false;
    expect((await request(app).post(endpoint).set("Authorization", "Bearer expired").send({ column_id: column })).status).toBe(401);
    mocks.authenticated = true; mocks.active = false;
    expect((await request(app).post(endpoint).set("Authorization", "Bearer test").send({ column_id: column })).status).toBe(403);
    mocks.active = true; mocks.ready = false;
    expect((await request(app).post(endpoint).set("Authorization", "Bearer test").send({ column_id: column })).status).toBe(403);
    expect(mocks.move).not.toHaveBeenCalled();
  });
  it("validates all IDs and rejects injected authority or metadata", async () => {
    for (const body of [{ column_id: "bad" }, { column_id: column, before_id: "bad" },
      { column_id: column, actor_id: card }, { column_id: column, project_id: card }, { column_id: column, position: 1 }]) {
      expect((await request(app).post(endpoint).set("Authorization", "Bearer test").send(body)).status).toBe(400);
    }
    expect((await request(app).post("/api/cards/bad/move").set("Authorization", "Bearer test").send({ column_id: column })).status).toBe(400);
    expect(mocks.move).not.toHaveBeenCalled();
  });
  it.each([["42501", 403], ["P0001", 409]])("does not expose DB details on %s", async (code, status) => {
    mocks.move.mockResolvedValue({ data: null, error: { code, message: "private-database-details" } });
    const result = await request(app).post(endpoint).set("Authorization", "Bearer test").send({ column_id: column });
    expect(result.status).toBe(status);
    expect(result.text).not.toContain("private-database-details");
  });
  it("finishes an accepted database operation after the HTTP client disconnects", async () => {
    let start!: () => void, commit!: (result: unknown) => void;
    const started = new Promise<void>((resolve) => { start = resolve; });
    const database = new Promise((resolve) => { commit = resolve; });
    let committed = false;
    mocks.move.mockImplementation(async () => {
      start();
      const result = await database;
      committed = true;
      return result;
    });
    const server = app.listen(0, "127.0.0.1");
    await once(server, "listening");
    const body = JSON.stringify({ column_id: column });
    const client = httpRequest({ hostname: "127.0.0.1", port: (server.address() as AddressInfo).port,
      path: endpoint, method: "POST", headers: { Authorization: "Bearer test", "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) } });
    client.on("error", () => {}); // Expected ECONNRESET from our deliberate disconnect.
    try {
      client.end(body);
      await started;
      expect(committed).toBe(false);
      const closed = new Promise<void>((resolve) => client.once("close", resolve));
      client.destroy();
      await closed;
      commit({ data: [{ id: card, column_id: column }], error: null });
      await vi.waitFor(() => expect(committed).toBe(true));
      expect(mocks.move).toHaveBeenCalledTimes(1);
      expect(mocks.adminRpc).not.toHaveBeenCalled();
    } finally {
      commit({ data: [], error: null });
      client.destroy();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });
});
