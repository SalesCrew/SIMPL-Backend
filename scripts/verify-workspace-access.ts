import "dotenv/config";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { writeFile } from "node:fs/promises";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import request from "supertest";
import app from "../server.js";
import { BUCKET, removeAttachment } from "../src/attachments.js";

const options = { auth: { persistSession: false, autoRefreshToken: false } };
const url = process.env.SUPABASE_URL!;
const key = process.env.SUPABASE_PUBLISHABLE_KEY!;
const root = createClient(url, process.env.SUPABASE_SECRET_KEY!, options);
const client = () => createClient(url, key, options);
const stamp = randomUUID().slice(0, 8);
const workspaces = ["A", "B", "C", "Shared"].map((name) => ({
  id: randomUUID(),
  name: `Isolation QA ${stamp} ${name}`,
}));
type Account = {
  id: string;
  email: string;
  password: string;
  token: string;
  db: SupabaseClient;
};
const users: Account[] = [];
const cardIds: string[] = [];
const attachmentIds: string[] = [];
const ok = (name: string) => console.log("PASS " + name);
function result<T extends { data: unknown; error: unknown }>(
  r: T,
): NonNullable<T["data"]> {
  assert.equal(r.error, null, JSON.stringify(r.error));
  return r.data as NonNullable<T["data"]>;
}
async function account(home: string, role = "mitarbeiter") {
  const email = `isolation-qa-${stamp}-${users.length}@example.com`,
    password = randomUUID() + "!Aa8";
  const created = result(
    await root.auth.admin.createUser({ email, password, email_confirm: true }),
  );
  const id = created.user!.id;
  const user: Account = { id, email, password, token: "", db: client() };
  users.push(user);
  result(
    await root.from("profiles").insert({
      id,
      email,
      name:
        role === "admin"
          ? "Isolation QA Admin"
          : `Isolation QA Team ${users.length - 1}`,
      role,
      default_workspace_id: home,
      default_column_id: null,
      active: true,
      color: "sage",
    }),
  );
  user.token = result(
    await user.db.auth.signInWithPassword({ email, password }),
  ).session!.access_token;
  return user;
}
async function api(
  user: Account,
  method: "post" | "delete" | "get",
  path: string,
  body?: object,
  expected = 200,
) {
  const r = await request(process.env.TEST_ISOLATION_API_URL || app)
    [method]("/api" + path)
    .set("Authorization", "Bearer " + user.token)
    .send(body);
  assert.equal(r.status, expected, JSON.stringify(r.body));
  return r.body;
}
async function hidden(
  db: SupabaseClient,
  table: string,
  column: string,
  value: string,
) {
  const r = await db.from(table).select("*").eq(column, value);
  assert.ok(r.error || r.data?.length === 0, table + " leaked blocked rows");
}
async function deniedMutation(
  query: PromiseLike<{ data: unknown; error: unknown }>,
) {
  const r = await query;
  assert.ok(
    r.error || (Array.isArray(r.data) && !r.data.length),
    "Unauthorized mutation succeeded",
  );
}
async function save(
  admin: Account,
  index: number,
  isolated: boolean,
  blocked: string[] = [],
) {
  const w = workspaces[index];
  result(
    await admin.db.rpc("save_workspace", {
      p_id: w.id,
      p_name: w.name,
      p_color: "sage",
      p_isolated: isolated,
      p_blocked: blocked,
    }),
  );
}
let keep = false;
try {
  // Bootstrap the test administrator in the existing default workspace, then use the real admin RPC.
  const existing = result(
    await root
      .from("workspaces")
      .select("id")
      .order("created_at")
      .limit(1)
      .single(),
  );
  const admin = await account(existing.id, "admin");
  for (let i = 0; i < workspaces.length; i++) await save(admin, i, false);
  const [wa, wb, wc, shared] = workspaces;
  const a = await account(wa.id),
    b = await account(wb.id),
    c = await account(wc.id);
  const columns = result(
    await admin.db
      .from("columns")
      .select("*")
      .in(
        "workspace_id",
        workspaces.map((w) => w.id),
      ),
  );
  const project = (workspace: string) =>
    columns.find(
      (col) => col.workspace_id === workspace && col.kind === "project",
    )!;
  const makeCard = async (owner: Account, workspace: string, title: string) => {
    const p = project(workspace);
    const row = result(
      await owner.db
        .from("cards")
        .insert({
          title,
          column_id: p.id,
          project_id: p.id,
          assignee_id: owner.id,
        })
        .select()
        .single(),
    );
    cardIds.push(row.id);
    return row;
  };
  const ca = await makeCard(a, wa.id, "Isolation QA · vertraulich A");
  const cb = await makeCard(b, wb.id, "Isolation QA · vertraulich B");
  const cc = await makeCard(c, wc.id, "Isolation QA · vertraulich C");
  const cs = await makeCard(a, shared.id, "Isolation QA · gemeinsames Board");
  const secretLabel = result(
    await b.db
      .from("labels")
      .insert({
        workspace_id: wb.id,
        name: "NDA intern " + stamp,
        color: "rose",
      })
      .select()
      .single(),
  );
  result(
    await b.db
      .from("cards")
      .update({ label_ids: [secretLabel.id] })
      .eq("id", cb.id),
  );
  result(
    await a.db
      .from("comments")
      .insert({ card_id: cb.id, body: "Earlier authorized participation" }),
  );
  result(
    await b.db
      .from("comments")
      .insert({ card_id: cb.id, body: "Old confidential notification" }),
  );
  assert.ok(
    result(await a.db.from("notifications").select("*").eq("card_id", cb.id))
      .length,
  );
  const ready = await api(
    b,
    "post",
    "/attachments",
    { card_id: cb.id, filename: "confidential.txt", size_bytes: 12 },
    201,
  );
  attachmentIds.push(ready.id);
  result(
    await b.db.storage
      .from(BUCKET)
      .upload(ready.object_path, Buffer.from("NDA contents"), {
        contentType: "text/plain",
        cacheControl: "0",
      }),
  );
  await api(b, "post", `/attachments/${ready.id}/complete`);
  await api(a, "get", `/attachments/${ready.id}/download`);
  const pending = await api(
    a,
    "post",
    "/attachments",
    { card_id: cb.id, filename: "pending.txt", size_bytes: 3 },
    201,
  );
  attachmentIds.push(pending.id);

  await save(admin, 0, false, [wb.id]);
  await save(admin, 2, true);
  for (const [person, own, other] of [
    [a, wa, wb],
    [b, wb, wa],
  ] as const) {
    const context = result(await person.db.rpc("workspace_access_context"));
    assert.equal(context.profile.default_workspace_id, own.id);
    assert.ok(context.workspaces.some((w: { id: string }) => w.id === own.id));
    assert.ok(
      context.workspaces.some((w: { id: string }) => w.id === shared.id),
    );
    assert.ok(
      !context.workspaces.some(
        (w: { id: string }) => w.id === other.id || w.id === wc.id,
      ),
    );
  }
  const isolated = result(await c.db.rpc("workspace_access_context"));
  assert.deepEqual(
    isolated.workspaces.map((w: { id: string }) => w.id),
    [wc.id],
  );
  assert.equal(
    result(
      await admin.db
        .from("workspaces")
        .select("id")
        .in(
          "id",
          workspaces.map((w) => w.id),
        ),
    ).length,
    4,
  );
  ok(
    "symmetric A/B denial, full C isolation both directions, shared board without bridging, admin override",
  );

  for (const [table, column, value] of [
    ["workspaces", "id", wb.id],
    ["columns", "workspace_id", wb.id],
    ["cards", "id", cb.id],
    ["comments", "card_id", cb.id],
    ["notifications", "card_id", cb.id],
    ["attachments", "card_id", cb.id],
    ["labels", "id", secretLabel.id],
    ["profiles", "id", b.id],
    ["workspace_blocks", "workspace_a", wa.id],
  ])
    await hidden(a.db, table, column, value);
  const ownSignals = result(await a.db.from("access_revisions").select("*"));
  assert.deepEqual(
    ownSignals.map((r) => r.id),
    [a.id],
  );
  assert.deepEqual(Object.keys(ownSignals[0]).sort(), [
    "authorization_version",
    "board_version",
    "id",
  ]);
  await hidden(client(), "cards", "id", ca.id);
  assert.ok((await client().rpc("workspace_access_context")).error);
  ok(
    "all related tables, personal notifications, profiles, scoped labels and anonymous reads",
  );

  await deniedMutation(
    a.db.from("cards").update({ title: "forged" }).eq("id", cb.id).select(),
  );
  await deniedMutation(a.db.from("cards").delete().eq("id", cb.id).select());
  await deniedMutation(
    a.db
      .from("cards")
      .insert({
        title: "forged",
        workspace_id: wb.id,
        column_id: project(wb.id).id,
        project_id: project(wb.id).id,
      })
      .select(),
  );
  await deniedMutation(
    a.db.from("comments").insert({ card_id: cb.id, body: "forged" }).select(),
  );
  await deniedMutation(
    a.db
      .from("labels")
      .update({ name: "forged" })
      .eq("id", secretLabel.id)
      .select(),
  );
  await deniedMutation(
    a.db
      .from("labels")
      .insert({ workspace_id: wb.id, name: "forged", color: "green" })
      .select(),
  );
  assert.ok(
    (
      await a.db.rpc("move_card", {
        p_card: cb.id,
        p_column: project(wa.id).id,
      })
    ).error,
  );
  assert.ok(
    (await a.db.rpc("set_card_completed", { p_card: cb.id, p_completed: true }))
      .error,
  );
  assert.ok(
    (
      await a.db
        .from("cards")
        .update({ label_ids: [secretLabel.id] })
        .eq("id", ca.id)
    ).error,
  );
  assert.ok(
    (await a.db.from("cards").update({ assignee_id: b.id }).eq("id", ca.id))
      .error,
  );
  result(
    await a.db
      .from("cards")
      .update({ title: "Isolation QA · gemeinsames Board" })
      .eq("id", cs.id),
  );
  result(
    await a.db.rpc("set_card_completed", { p_card: ca.id, p_completed: true }),
  );
  await deniedMutation(
    a.db
      .from("profiles")
      .update({ role: "admin", default_workspace_id: wb.id })
      .eq("id", a.id)
      .select(),
  );
  await deniedMutation(
    a.db
      .from("workspaces")
      .update({ isolated: false })
      .eq("id", wc.id)
      .select(),
  );
  await deniedMutation(a.db.from("workspace_blocks").delete().select());
  await deniedMutation(
    a.db
      .from("access_revisions")
      .update({ authorization_version: 1 })
      .eq("id", a.id)
      .select(),
  );
  assert.ok(
    (
      await a.db.rpc("save_workspace", {
        p_id: wa.id,
        p_name: wa.name,
        p_color: "sage",
        p_isolated: false,
        p_blocked: [],
      })
    ).error,
  );
  assert.ok(
    (
      await a.db.schema("private").rpc("user_can_access_workspace", {
        p_user: admin.id,
        p_workspace: wb.id,
      })
    ).error,
  );
  result(
    await a.db.auth.updateUser({
      data: {
        role: "admin",
        default_workspace_id: wb.id,
        workspace_id: shared.id,
      },
    }),
  );
  await a.db.auth.refreshSession();
  await hidden(a.db, "cards", "id", cb.id);
  const oldTokenClient = createClient(url, key, {
    ...options,
    global: { headers: { Authorization: "Bearer " + a.token } },
  });
  await hidden(oldTokenClient, "cards", "id", cb.id);
  ok(
    "direct inserts/updates/deletes, RPCs, cross-workspace labels/assignees, admin-only controls, forged metadata and old JWT",
  );

  assert.ok(
    (await a.db.storage.from(BUCKET).download(ready.object_path)).error,
  );
  await api(a, "get", `/attachments/${ready.id}/download`, undefined, 404);
  assert.ok(
    (
      await a.db.storage
        .from(BUCKET)
        .upload(pending.object_path, Buffer.from("abc"), {
          contentType: "text/plain",
        })
    ).error,
  );
  assert.ok(
    (await a.db.storage.from(BUCKET).createSignedUrl(ready.object_path, 60))
      .error,
  );
  await api(
    a,
    "post",
    "/attachments",
    { card_id: cb.id, filename: "forged.txt", size_bytes: 1 },
    404,
  );
  await api(a, "post", `/attachments/${pending.id}/complete`, undefined, 404);
  await api(a, "delete", `/attachments/${ready.id}`, undefined, 204);
  assert.equal(
    result(await root.from("attachments").select("id").eq("id", ready.id))
      .length,
    1,
    "Hidden delete must be a no-op",
  );
  await api(a, "delete", `/cards/${cb.id}`, undefined, 404);
  await api(admin, "get", `/attachments/${ready.id}/download`);
  assert.ok(
    (await admin.db.storage.from(BUCKET).download(ready.object_path)).error,
  );
  assert.equal(
    result(await admin.db.from("attachments").select("*").eq("id", pending.id))
      .length,
    1,
  );
  result(
    await b.db
      .from("comments")
      .insert({ card_id: cb.id, body: "After revocation" }),
  );
  const forbiddenNotifications = result(
    await root
      .from("notifications")
      .select("*")
      .eq("recipient_id", a.id)
      .eq("body", "After revocation"),
  );
  assert.equal(forbiddenNotifications.length, 0);
  ok(
    "private Storage bytes, previously reserved uploads, signed URLs, backend routes and notification fan-out",
  );

  await a.db.realtime.setAuth(
    result(await a.db.auth.getSession()).session!.access_token,
  );
  const events: Array<{
    table: string;
    new: Record<string, unknown>;
    old: Record<string, unknown>;
  }> = [];
  const channel = a.db
    .channel("isolation-qa-" + stamp)
    .on("postgres_changes", { event: "*", schema: "public" }, (event) =>
      events.push(event),
    );
  await new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(
      () => reject(new Error("Realtime readiness timeout")),
      20000,
    );
    channel
      .on("system", {}, (p) => {
        if (p.extension === "postgres_changes" && p.status === "ok") {
          clearTimeout(timeout);
          resolve();
        }
      })
      .subscribe();
  });
  events.length = 0;
  result(
    await b.db
      .from("cards")
      .update({ description: "Must not broadcast" })
      .eq("id", cb.id),
  );
  result(
    await a.db
      .from("cards")
      .update({ description: "Visible change" })
      .eq("id", ca.id),
  );
  for (let i = 0; i < 40 && !events.length; i++)
    await new Promise((r) => setTimeout(r, 150));
  assert.ok(events.length, "No own revision event");
  assert.ok(
    events.every((e) => e.table === "access_revisions" && e.new.id === a.id),
  );
  assert.ok(
    events.every((e) =>
      Object.keys(e.new).every((k) =>
        ["id", "authorization_version", "board_version"].includes(k),
      ),
    ),
  );
  await a.db.removeChannel(channel);
  const previous = result(await a.db.rpc("workspace_access_context")).revision
    .authorization_version;
  result(
    await root
      .from("profiles")
      .update({ default_workspace_id: wc.id })
      .eq("id", a.id),
  );
  const moved = result(await oldTokenClient.rpc("workspace_access_context"));
  assert.ok(moved.revision.authorization_version > previous);
  assert.deepEqual(
    moved.workspaces.map((w: { id: string }) => w.id),
    [wc.id],
  );
  await hidden(oldTokenClient, "cards", "id", ca.id);
  result(await root.from("profiles").update({ active: false }).eq("id", a.id));
  const inactive = result(await oldTokenClient.rpc("workspace_access_context"));
  assert.equal(inactive.profile, null);
  assert.deepEqual(inactive.workspaces, []);
  await hidden(oldTokenClient, "cards", "id", cc.id);
  result(
    await root
      .from("profiles")
      .update({ active: true, default_workspace_id: wa.id })
      .eq("id", a.id),
  );
  ok(
    "Realtime only sends own opaque revisions; home reassignment and deactivation revoke old-token access immediately",
  );
  if (process.argv.includes("--keep-ui")) {
    await writeFile(
      ".workspace-access-qa.json",
      JSON.stringify(
        {
          stamp,
          workspaces,
          users: users.map(({ db, ...user }) => user),
          cards: cardIds,
          attachments: attachmentIds,
        },
        null,
        2,
      ),
    );
    keep = true;
    console.log("UI fixture saved locally; credentials not printed.");
  }
} finally {
  for (const u of users) await u.db.removeAllChannels();
  if (!keep) {
    for (const id of attachmentIds) await removeAttachment(root, id);
    if (cardIds.length)
      result(await root.from("cards").delete().in("id", cardIds));
    for (const u of [...users].reverse())
      result(await root.auth.admin.deleteUser(u.id));
    console.log(
      "Removed QA files, cards and accounts. Remove only these empty QA workspaces with the scoped SQL cleanup:",
      JSON.stringify(workspaces),
    );
  }
}
