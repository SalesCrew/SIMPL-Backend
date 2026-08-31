import "dotenv/config";
import { randomBytes, randomUUID } from "node:crypto";
import assert from "node:assert/strict";
import request from "supertest";
import { createClient } from "@supabase/supabase-js";
import app from "../server.js";

// Disposable, isolated fixture. Credentials and tokens are never printed.
const url = process.env.SUPABASE_URL!;
const key = process.env.SUPABASE_PUBLISHABLE_KEY!;
const admin = createClient(url, process.env.SUPABASE_SECRET_KEY!, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const client = createClient(url, key, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const workspaceId = randomUUID();
const cardId = randomUUID();
const sessionId = randomUUID();
const email = `codex-card-edit-${randomUUID()}@example.invalid`;
const password = randomBytes(30).toString("base64url");
let actorId = "";
let token = "";
function checked<R extends { data: unknown; error: unknown }>(result: R): NonNullable<R["data"]> {
  if (result.error) throw result.error;
  return result.data as NonNullable<R["data"]>;
}
const rpc = async (operation: string, action?: unknown) =>
  checked(
    await client.rpc("card_edit_session", {
      p_session: sessionId,
      p_operation: operation,
      p_card: cardId,
      p_action: action || null,
    }),
  );
async function upload(filename: string, body: string, session = false) {
  const prepared = await request(app)
    .post("/api/attachments")
    .set("Authorization", `Bearer ${token}`)
    .send({
      card_id: cardId,
      filename,
      size_bytes: Buffer.byteLength(body),
      ...(session ? { edit_session_id: sessionId } : {}),
    });
  assert.equal(prepared.status, 201, JSON.stringify(prepared.body));
  const item = prepared.body;
  checked(
    await client.storage
      .from("card-attachments")
      .upload(item.object_path, Buffer.from(body), {
        contentType: "text/plain",
        upsert: false,
      }),
  );
  const completed = await request(app)
    .post(`/api/attachments/${item.id}/complete`)
    .set("Authorization", `Bearer ${token}`);
  assert.equal(completed.status, 200, JSON.stringify(completed.body));
  assert.equal(completed.body.status, "ready");
  return completed.body;
}
try {
  checked(
    await admin
      .from("workspaces")
      .insert({
        id: workspaceId,
        name: `Card edit storage QA ${workspaceId.slice(0, 8)}`,
        color: "sage",
        isolated: true,
      }),
  );
  const created = checked(
    await admin.auth.admin.createUser({ email, password, email_confirm: true }),
  );
  actorId = created.user!.id;
  checked(
    await admin
      .from("profiles")
      .insert({
        id: actorId,
        email,
        name: "Card edit QA",
        role: "admin",
        default_workspace_id: workspaceId,
        color: "sage",
      }),
  );
  const login = checked(
    await client.auth.signInWithPassword({ email, password }),
  );
  token = login.session!.access_token;
  const column = checked(
    await client
      .from("columns")
      .select("id")
      .eq("workspace_id", workspaceId)
      .eq("kind", "project")
      .single(),
  );
  checked(
    await client
      .from("cards")
      .insert({
        id: cardId,
        title: "Original file fixture",
        column_id: column.id,
        project_id: column.id,
      }),
  );
  const original = await upload("before.txt", "original bytes");
  await rpc("begin");
  await rpc("mutate", { type: "attachment.delete", id: original.id });
  assert.ok(
    (
      await client.storage
        .from("card-attachments")
        .download(original.object_path)
    ).error,
    "Removed bytes must not remain downloadable",
  );
  // The old delete endpoint must not physically remove a held file.
  const directDelete = await request(app)
    .delete(`/api/attachments/${original.id}`)
    .set("Authorization", `Bearer ${token}`);
  assert.equal(directDelete.status, 204);
  const added = await upload("during.txt", "new bytes", true);
  const done = await rpc("close");
  assert.equal(
    done.events.filter(
      (event: { field: string }) => event.field === "attachment",
    ).length,
    2,
  );
  await rpc("hold");
  await rpc("undo");
  const restored = checked(
    await client.storage
      .from("card-attachments")
      .download(original.object_path),
  );
  assert.equal(await restored.text(), "original bytes");
  assert.ok(
    (await client.storage.from("card-attachments").download(added.object_path))
      .error,
    "Undone upload must not be downloadable",
  );
  const cleanup = await request(app)
    .post(`/api/cards/${cardId}/cleanup`)
    .set("Authorization", `Bearer ${token}`);
  assert.equal(cleanup.status, 204, JSON.stringify(cleanup.body));
  assert.equal(
    checked(await admin.from("attachments").select("id").eq("id", added.id))
      .length,
    0,
  );
  assert.ok(
    (await admin.storage.from("card-attachments").info(added.object_path))
      .error,
    "Undone upload bytes must be removed",
  );
  console.log(
    "PASS: real API upload, byte validation, private download, retained deletion, session undo, and physical Storage cleanup.",
  );
} finally {
  if (token) {
    await rpc("discard").catch(() => {});
    const removed = await request(app)
      .delete(`/api/cards/${cardId}`)
      .set("Authorization", `Bearer ${token}`);
    if (![204, 404].includes(removed.status))
      throw new Error(
        "QA card cleanup failed; inspect the known fixture before deleting anything else.",
      );
  }
  if (actorId) {
    checked(await admin.from("profiles").delete().eq("id", actorId));
    checked(await admin.auth.admin.deleteUser(actorId));
  }
  checked(await admin.from("labels").delete().eq("workspace_id", workspaceId));
  // Fixed-column protection intentionally blocks workspace deletion via client APIs.
  // An owner must remove this empty fixture with the guarded SQL cleanup after a run.
  console.log(
    `QA cards, accounts and files cleaned. Empty workspace for owner cleanup: ${workspaceId}`,
  );
}
