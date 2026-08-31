import { describe, expect, it } from "vitest";
import request from "supertest";
import app from "../server.js";
import { initialPasswordSchema } from "../src/initial-password.js";

describe("Mandatory initial password validation", () => {
  it("requires authentication before processing the password", async () => {
    const response = await request(app).post("/api/account/initial-password")
      .send({ password: "long-new-password", repeatPassword: "long-new-password" });
    expect(response.status).toBe(401);
  });
  it("rejects mismatches, short/oversize passwords and injected account IDs", () => {
    const valid = { password: "long-new-password", repeatPassword: "long-new-password" };
    expect(initialPasswordSchema.safeParse(valid).success).toBe(true);
    for (const value of [
      { ...valid, repeatPassword: "something-else" },
      { password: "short", repeatPassword: "short" },
      { password: "a".repeat(129), repeatPassword: "a".repeat(129) },
      { ...valid, user_id: "someone-else" },
      { ...valid, completed: true },
    ]) expect(initialPasswordSchema.safeParse(value).success).toBe(false);
  });
});
