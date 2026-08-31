import "dotenv/config";
import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import request from "supertest";
import app from "../server.js";

const url = process.env.SUPABASE_URL!;
assert.equal(url, "https://xqvexzoswhraqicbmckj.supabase.co");
const key = process.env.SUPABASE_PUBLISHABLE_KEY!;
const admin = createClient(url, process.env.SUPABASE_SECRET_KEY!, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const client = (token?: string) => createClient(url, key, {
  auth: { persistSession: false, autoRefreshToken: false },
  ...(token ? { global: { headers: { Authorization: `Bearer ${token}` } } } : {}),
});
const api = process.env.TEST_API_URL || app;
const accounts: string[] = [];
const password = () => randomBytes(20).toString("base64url") + "Aa7!";
try {
  const workspaces = await admin.from("workspaces").select("id").eq("name", "Development").single();
  assert.ifError(workspaces.error);
  for (const role of ["admin", "mitarbeiter"]) {
    const email = `qa-first-password-${randomUUID()}@example.invalid`;
    const temporary = password();
    const changed = password();
    const created = await admin.auth.admin.createUser({ email, password: temporary, email_confirm: true });
    assert.ifError(created.error);
    const id = created.data.user!.id;
    accounts.push(id);
    assert.ifError((await admin.from("profiles").insert({ id, name: "Temporary password verification", email,
      role, color: "sage", active: true, default_workspace_id: workspaces.data!.id, default_column_id: null })).error);
    const signedIn = client();
    const login = await signedIn.auth.signInWithPassword({ email, password: temporary });
    assert.ifError(login.error);
    const oldToken = login.data.session!.access_token;
    const oldClient = client(oldToken);
    const context = await oldClient.rpc("account_access_context");
    assert.ifError(context.error);
    assert.equal(context.data.ready, false);
    assert.equal(context.data.security.password_change_required, true);
    for (const table of ["profiles", "workspaces", "columns", "cards", "comments", "attachments", "labels", "notifications", "access_revisions"]) {
      const read = await oldClient.from(table).select("*");
      assert.ifError(read.error);
      assert.deepEqual(read.data, [], `Temporary password exposed ${table}`);
    }
    const forged = await oldClient.from("account_security").update({ password_change_required: false, password_changed_at: new Date().toISOString() }).eq("user_id", id);
    assert.ok(forged.error, "Client forged password completion");
    const own = await oldClient.from("account_security").select("user_id,password_change_required,password_changed_at");
    assert.ifError(own.error);
    assert.deepEqual(own.data?.map(row => row.user_id), [id]);
    assert.ok((await oldClient.rpc("complete_password_change", { p_user: id, p_operation: randomUUID() })).error);
    for (const endpoint of ["/api/users", `/api/attachments/${randomUUID()}/download`]) {
      const denied = await request(api).get(endpoint).set("Authorization", `Bearer ${oldToken}`);
      assert.equal(denied.status, 403);
    }
    const mismatch = await request(api).post("/api/account/initial-password")
      .set("Authorization", `Bearer ${oldToken}`).send({ password: changed, repeatPassword: "different-password" });
    assert.equal(mismatch.status, 400);
    const unchanged = await request(api).post("/api/account/initial-password")
      .set("Authorization", `Bearer ${oldToken}`).send({ password: temporary, repeatPassword: temporary });
    assert.equal(unchanged.status, 400, `Unchanged password accepted: ${unchanged.text}`);
    const result = await request(api).post("/api/account/initial-password")
      .set("Authorization", `Bearer ${oldToken}`).send({ password: changed, repeatPassword: changed });
    assert.equal(result.status, 200, `Password change failed: ${result.text}`);
    const stamp = await admin.from("account_security").select("password_change_required,password_changed_at").eq("user_id", id).single();
    assert.ifError(stamp.error);
    assert.equal(stamp.data!.password_change_required, false);
    assert.ok(stamp.data!.password_changed_at);
    const staleRead = await oldClient.from("columns").select("id");
    assert.ok(staleRead.error || staleRead.data?.length === 0, "Old temporary-password token gained access");
    const fresh = client();
    const relogin = await fresh.auth.signInWithPassword({ email, password: changed });
    assert.ifError(relogin.error);
    const access = await fresh.rpc("account_access_context");
    assert.ifError(access.error);
    assert.equal(access.data.ready, true);
    assert.equal(access.data.security.password_change_required, false);
    assert.equal((await fresh.from("columns").select("id")).data?.length, 6);
    const repeated = await request(api).post("/api/account/initial-password")
      .set("Authorization", `Bearer ${relogin.data.session!.access_token}`)
      .send({ password: password(), repeatPassword: password() });
    assert.equal(repeated.status, 400);
    const another = password();
    const alreadyDone = await request(api).post("/api/account/initial-password")
      .set("Authorization", `Bearer ${relogin.data.session!.access_token}`)
      .send({ password: another, repeatPassword: another });
    assert.equal(alreadyDone.status, 409);
    assert.ifError((await admin.rpc("require_password_change", { p_user: id })).error);
    assert.equal((await fresh.rpc("account_access_context")).data.ready, false);
    assert.deepEqual((await fresh.from("columns").select("id")).data, []);
    await fresh.auth.signOut();
    console.log(`PASS ${role}: first-login gate, all data/API denial, unforgeable stamp, password change, new-session access, old-token denial and reset`);
  }
} finally {
  for (const id of accounts) {
    const removed = await admin.auth.admin.deleteUser(id);
    assert.ifError(removed.error);
  }
}
console.log("PASS: temporary verification accounts removed; requested accounts untouched.");
