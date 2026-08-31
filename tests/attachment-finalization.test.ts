import { describe, expect, it, vi } from "vitest";
import express from "express";
import request from "supertest";
import { attachmentRouter } from "../src/attachments.js";

describe("large file finalization", () => {
  it("checks Storage metadata without downloading 500 MB into the API", async () => {
    const item = {
      id: "40000000-0000-4000-8000-000000000001",
      card_id: "40000000-0000-4000-8000-000000000002",
      uploaded_by: "40000000-0000-4000-8000-000000000003",
      object_path: "card/file",
      size_bytes: 500 * 1024 * 1024,
      mime_type: "application/octet-stream",
      status: "pending",
      expires_at: new Date(Date.now() + 86400000).toISOString(),
    };
    const download = vi.fn(() => {
      throw new Error("Large file must not be downloaded by API");
    });
    const info = vi
      .fn()
      .mockResolvedValue({
        data: { size: item.size_bytes, contentType: item.mime_type },
        error: null,
      });
    let updated = false;
    const query = {
      select: vi.fn(() => query),
      eq: vi.fn(() => query),
      gt: vi.fn(() => query),
      update: vi.fn(() => {
        updated = true;
        return query;
      }),
      maybeSingle: vi.fn(async () => ({
        data: { ...item, status: updated ? "ready" : "pending" },
        error: null,
      })),
    };
    const userQuery = {
      select: () => userQuery,
      eq: () => userQuery,
      maybeSingle: async () => ({ data: { id: item.card_id }, error: null }),
    };
    const app = express();
    app.use((_req, res, next) => {
      res.locals.actor = item.uploaded_by;
      res.locals.admin = {
        from: () => query,
        storage: { from: () => ({ info, download }) },
      };
      res.locals.user = { from: () => userQuery };
      next();
    });
    app.use(attachmentRouter);
    const response = await request(app).post(`/${item.id}/complete`);
    expect(response.status).toBe(200);
    expect(response.body.status).toBe("ready");
    expect(info).toHaveBeenCalledWith(item.object_path);
    expect(download).not.toHaveBeenCalled();
    expect(query.update).toHaveBeenCalledWith({ status: "ready" });
  });
});
