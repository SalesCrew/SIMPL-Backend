import "dotenv/config";
import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import request from "supertest";
import app from "../server.js";

const url = process.env.SUPABASE_URL!;
assert.equal(url, "https://xqvexzoswhraqicbmckj.supabase.co");
const options = { auth: { persistSession: false, autoRefreshToken: false } };
const admin = createClient(url, process.env.SUPABASE_SECRET_KEY!, options);
const member = createClient(url, process.env.SUPABASE_PUBLISHABLE_KEY!, options);
const api = process.env.TEST_API_URL || app;
const projectIds: string[] = [], cardIds: string[] = [];
let actor: string | undefined;
const checked = <R extends { data: unknown; error: unknown }>(result: R): NonNullable<R["data"]> => {
  if (result.error) throw result.error;
  assert.notEqual(result.data, null);
  return result.data as NonNullable<R["data"]>;
};
try {
  const workspace = checked(await admin.from("workspaces").select("id").eq("name", "Development").single());
  // move_card rebalances destination positions. Never use a real project/bucket.
  for (const name of ["source", "destination"]) {
    const id = randomUUID(); projectIds.push(id);
    checked(await admin.from("columns").insert({ id, workspace_id: workspace.id, name: `QA move ${name} ${id}`, kind: "project", color: "slate", position: 1000 }).select("id").single());
  }
  const email = `qa-card-moves-${randomUUID()}@example.invalid`;
  const temporary = randomBytes(24).toString("base64url") + "Aa8!";
  const password = randomBytes(24).toString("base64url") + "Aa9!";
  actor = checked(await admin.auth.admin.createUser({ email, password: temporary, email_confirm: true })).user!.id;
  assert.ifError((await admin.from("profiles").insert({ id: actor, email, name: "Disposable move verification", role: "mitarbeiter", color: "sage", active: true,
    default_workspace_id: workspace.id, default_column_id: projectIds[0] })).error);
  let login = checked(await member.auth.signInWithPassword({ email, password: temporary }));
  const denied = await request(api).post(`/api/cards/${randomUUID()}/move`).set("Authorization", `Bearer ${login.session!.access_token}`).send({ column_id: projectIds[1] });
  assert.equal(denied.status, 403, "Initial password gate must precede moves");
  const changed = await request(api).post("/api/account/initial-password").set("Authorization", `Bearer ${login.session!.access_token}`).send({ password, repeatPassword: password });
  assert.equal(changed.status, 200, changed.text);
  login = checked(await member.auth.signInWithPassword({ email, password }));
  const token = login.session!.access_token;
  const move = (id: string, column: string, before: string | null = null) => request(api).post(`/api/cards/${id}/move`)
    .set("Authorization", `Bearer ${token}`).send({ column_id: column, before_id: before });
  for (let index = 0; index < 6; index++) {
    const id = randomUUID(); cardIds.push(id);
    assert.ifError((await member.from("cards").insert({ id, title: `Disposable move card ${index}`, column_id: projectIds[index < 3 ? 0 : 1],
      project_id: projectIds[index < 3 ? 0 : 1], position: (index + 1) * 73 })).error);
  }
  assert.ifError((await admin.from("cards").update({ archived_at: new Date().toISOString() }).eq("id", cardIds[5])).error);
  const archive = checked(await admin.from("cards").select("*").eq("id", cardIds[5]).single());
  const result = await move(cardIds[0], projectIds[1], cardIds[4]);
  assert.equal(result.status, 200, result.text);
  assert.deepEqual(result.body.cards.map((c: { id: string }) => c.id), [cardIds[3], cardIds[0], cardIds[4]]);
  assert.ok(result.body.cards.every((c: { edit_revision: number }) => c.edit_revision > 0));
  assert.equal(result.body.cards.find((c: { id: string }) => c.id === cardIds[0]).project_id, projectIds[0]);
  const saved = checked(await member.from("cards").select("*").eq("column_id", projectIds[1]).is("archived_at", null).is("deleted_at", null).order("position").order("id"));
  assert.deepEqual(result.body.cards, saved, "Receipt must include all rebalanced destination rows");
  assert.deepEqual(checked(await admin.from("cards").select("*").eq("id", cardIds[5]).single()), archive);
  const beforeFailed = checked(await member.from("cards").select("*").in("id", cardIds).order("id"));
  assert.equal((await move(cardIds[1], projectIds[1], randomUUID())).status, 409);
  assert.deepEqual(checked(await member.from("cards").select("*").in("id", cardIds).order("id")), beforeFailed, "Failed insertion must roll back rebalancing too");
  assert.equal((await move(cardIds[5], projectIds[0])).status, 409, "Archived card must not move");
  const concurrent = await Promise.all([move(cardIds[1], projectIds[1]), move(cardIds[2], projectIds[1])]);
  assert.ok(concurrent.every((r) => r.status === 200));
  const positions = checked(await member.from("cards").select("id,position").eq("column_id", projectIds[1]).is("archived_at", null));
  assert.equal(positions.length, 5);
  assert.equal(new Set(positions.map((c) => c.position)).size, 5, "Concurrent moves must have distinct positions");
  assert.equal((await move(cardIds[0], projectIds[1], cardIds[3])).status, 200, "Same-column reorder");
  assert.equal((await move(cardIds[0], projectIds[0])).status, 200, "Drop into empty project");
  const afterMoves = checked(await admin.from("cards").select("*").in("id", cardIds).order("id"));
  assert.ifError((await admin.rpc("require_password_change", { p_user: actor })).error);
  assert.equal((await move(cardIds[0], projectIds[1])).status, 403);
  assert.ok((await member.rpc("move_card_with_receipt", { p_card: cardIds[0], p_column: projectIds[1] })).error, "Console RPC must not bypass the gate");
  assert.deepEqual(checked(await admin.from("cards").select("*").in("id", cardIds).order("id")), afterMoves);
  console.log("PASS: authenticated API → atomic database move/receipt; exact ordering, concurrent moves, empty destinations, immutable archives, failed-transaction rollback and API/direct-RPC password denial.");
} finally {
  if (cardIds.length) assert.ifError((await admin.from("cards").delete().in("id", cardIds)).error);
  if (actor) assert.ifError((await admin.auth.admin.deleteUser(actor)).error);
  if (projectIds.length) assert.ifError((await admin.from("columns").delete().in("id", projectIds)).error);
}
console.log("PASS: only disposable QA cards/account/projects removed; no real card positions changed.");
