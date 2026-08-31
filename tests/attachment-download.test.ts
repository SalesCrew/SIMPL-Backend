import { afterEach, describe, expect, it, vi } from "vitest";
import express from "express";
import request from "supertest";
import { attachmentRouter, AttachmentError } from "../src/attachments.js";

const item = {
  id: "40000000-0000-4000-8000-000000000001",
  object_path: "card/file",
  filename: "Prüfnotiz.txt",
  mime_type: "text/plain",
  size_bytes: 4,
};
function harness(visible = true) {
  const query = {
    select: vi.fn(() => query),
    eq: vi.fn(() => query),
    maybeSingle: vi.fn(async () => ({
      data: visible ? item : null,
      error: null,
    })),
  };
  const app = express();
  app.use((_req, res, next) => {
    res.locals.user = { from: () => query };
    next();
  });
  app.use(attachmentRouter);
  app.use(
    (
      error: Error,
      _req: express.Request,
      res: express.Response,
      _next: express.NextFunction,
    ) => {
      res
        .status(error instanceof AttachmentError ? error.status : 400)
        .json({ error: error.message });
    },
  );
  return { app, query };
}
afterEach(() => {
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
});
describe("authenticated streaming downloads", () => {
  it("never contacts privileged Storage when live user RLS hides the file", async () => {
    const upstream = vi.fn();
    vi.stubGlobal("fetch", upstream);
    const { app, query } = harness(false);
    expect((await request(app).get(`/${item.id}/download`)).status).toBe(404);
    expect(query.eq).toHaveBeenCalledWith("id", item.id);
    expect(query.eq).toHaveBeenCalledWith("status", "ready");
    expect(upstream).not.toHaveBeenCalled();
  });
  it("streams bytes without forwarding CDN cache headers or credentials", async () => {
    vi.stubEnv("SUPABASE_URL", "https://storage.example.test");
    vi.stubEnv("SUPABASE_SECRET_KEY", "server-test-secret");
    const upstream = vi.fn(
      async () =>
        new Response("test", {
          headers: {
            "content-length": "4",
            "cache-control": "public, max-age=3600",
          },
        }),
    );
    vi.stubGlobal("fetch", upstream);
    const { app } = harness();
    const response = await request(app).get(`/${item.id}/download`);
    expect(response.status).toBe(200);
    expect(response.text).toBe("test");
    expect(response.headers["cache-control"]).toBe(
      "private, no-store, max-age=0",
    );
    expect(response.headers["cdn-cache-control"]).toBe("no-store");
    expect(response.headers.vary).toContain("Authorization");
    expect(response.headers["content-disposition"]).toContain("attachment");
    expect(JSON.stringify(response.headers)).not.toContain(
      "server-test-secret",
    );
  });
  it("preserves single byte ranges and rejects multipart ranges", async () => {
    vi.stubEnv("SUPABASE_URL", "https://storage.example.test");
    vi.stubEnv("SUPABASE_SECRET_KEY", "server-test-secret");
    const upstream = vi.fn(
      async (_input: RequestInfo | URL, _init?: RequestInit) =>
        new Response("te", {
          status: 206,
          headers: { "content-range": "bytes 0-1/4", "content-length": "2" },
        }),
    );
    vi.stubGlobal("fetch", upstream);
    const { app } = harness();
    const response = await request(app)
      .get(`/${item.id}/download`)
      .set("Range", "bytes=0-1");
    expect(response.status).toBe(206);
    expect(response.text).toBe("te");
    expect(response.headers["content-range"]).toBe("bytes 0-1/4");
    expect(upstream.mock.calls[0]?.[1]).toMatchObject({
      headers: { Range: "bytes=0-1" },
    });
    expect(
      (
        await request(app)
          .get(`/${item.id}/download`)
          .set("Range", "bytes=0-1,2-3")
      ).status,
    ).toBe(416);
    expect(upstream).toHaveBeenCalledTimes(1);
  });
});
