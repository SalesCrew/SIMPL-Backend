import { describe, expect, it } from "vitest";
import request from "supertest";
import app from "../server.js";
import { canEditProfile, createProfileSchema } from "../src/validation.js";
describe("Admin API access and validation", () => {
  it("accepts a default workspace ID and rejects invalid assignments", () => {
    const profile = {
      name: "Workspace Test",
      email: "workspaces@example.invalid",
      password: "long-enough-test-password",
      role: "mitarbeiter",
      color: "sage",
      default_column_id: null,
      active: true,
      default_workspace_id: "40000000-0000-4000-8000-000000000001",
    };
    expect(createProfileSchema.parse(profile).default_workspace_id).toBe(
      profile.default_workspace_id,
    );
    expect(
      createProfileSchema.safeParse({
        ...profile,
        default_workspace_id: "not-a-workspace",
      }).success,
    ).toBe(false);
  });
  it("accepts all 16 pastel colors and rejects unknown palette values", () => {
    const values = [
      "green",
      "blue",
      "purple",
      "orange",
      "rose",
      "slate",
      "mint",
      "sage",
      "teal",
      "sky",
      "periwinkle",
      "lavender",
      "pink",
      "peach",
      "butter",
      "sand",
    ];
    const profile = {
      name: "Palette Test",
      email: "palette@example.invalid",
      password: "long-enough-test-password",
      role: "mitarbeiter",
      default_column_id: null,
      active: true,
    };
    for (const color of values)
      expect(createProfileSchema.safeParse({ ...profile, color }).success).toBe(
        true,
      );
    expect(
      createProfileSchema.safeParse({ ...profile, color: "neon" }).success,
    ).toBe(false);
  });
  it("provides health without exposing secrets", async () => {
    const r = await request(app).get("/api/health");
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ ok: true, service: "simpl-backend" });
    expect(r.headers["cache-control"]).toBe("no-store");
  });
  it("requires authentication before any admin mutation", async () => {
    const r = await request(app).post("/api/users").send({ role: "admin" });
    expect(r.status).toBe(401);
  });
  it("requires authentication for card file cleanup", async () => {
    const r = await request(app).post(
      "/api/cards/00000000-0000-4000-8000-000000000001/cleanup",
    );
    expect(r.status).toBe(401);
  });
  it("requires authentication before streaming any file", async () => {
    const r = await request(app).get(
      "/api/attachments/00000000-0000-4000-8000-000000000001/download",
    );
    expect(r.status).toBe(401);
  });
  it("rejects unapproved cross-origin callers", async () => {
    const r = await request(app)
      .post("/api/users")
      .set("Origin", "https://untrusted.example")
      .send({});
    expect(r.status).toBe(403);
  });
  it("returns JSON for unknown routes", async () => {
    const r = await request(app).get("/api/missing");
    expect(r.status).toBe(404);
    expect(r.body.error).toBeTruthy();
  });
  it("rejects malformed request bodies", async () => {
    const r = await request(app)
      .post("/api/users")
      .set("Content-Type", "application/json")
      .send("{broken");
    expect(r.status).toBe(400);
  });
  it("requires a long password and valid email", () => {
    expect(
      createProfileSchema.safeParse({
        name: "User",
        email: "bad",
        password: "short",
        role: "admin",
        color: "green",
        default_column_id: null,
        active: true,
      }).success,
    ).toBe(false);
  });
  it("rejects unknown roles and strips extra authorization claims", () => {
    const user = {
      name: "User",
      email: "USER@example.com",
      password: "secure-password-long",
      role: "mitarbeiter",
      color: "green",
      default_column_id: null,
      active: true,
    };
    expect(createProfileSchema.parse(user).email).toBe("user@example.com");
    expect(
      createProfileSchema.safeParse({ ...user, role: "owner" }).success,
    ).toBe(false);
    expect(
      createProfileSchema.parse({ ...user, app_metadata: { role: "admin" } }),
    ).not.toHaveProperty("app_metadata");
  });
  it("blocks removal of the caller’s own admin access", () => {
    expect(
      canEditProfile("a", "a", { role: "mitarbeiter", active: true }),
    ).toBe(false);
    expect(canEditProfile("a", "a", { role: "admin", active: false })).toBe(
      false,
    );
    expect(
      canEditProfile("a", "b", { role: "mitarbeiter", active: true }),
    ).toBe(true);
  });
});
