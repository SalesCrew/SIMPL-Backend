import "dotenv/config";
import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
const url = process.env.SUPABASE_URL!;
const key = process.env.SUPABASE_PUBLISHABLE_KEY!;
const secret = process.env.SUPABASE_SECRET_KEY!;
if (!url || !key || !secret) throw new Error("Server configuration required.");
const api = process.env.TEST_API_URL || "http://127.0.0.1:3001";
const options = { auth: { persistSession: false, autoRefreshToken: false } };
const admin = createClient(url, secret, options);
const a = createClient(url, key, options);
const b = createClient(url, key, options);
const suffix = randomUUID();
const password = randomBytes(24).toString("base64url");
const accounts: string[] = [];
let cardId: string | undefined;
let labelId: string | undefined;
async function request(
  path: string,
  token: string | null,
  method = "GET",
  body?: unknown,
) {
  const response = await fetch(`${api}${path}`, {
    method,
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(20000),
  });
  return { status: response.status, data: await response.json() };
}
try {
  const created = await admin.auth.admin.createUser({
    email: `qa-admin-${suffix}@example.invalid`,
    password,
    email_confirm: true,
  });
  assert.ifError(created.error);
  const aId = created.data.user!.id;
  accounts.push(aId);
  assert.ifError(
    (
      await admin.from("profiles").insert({
        id: aId,
        name: "QA Admin",
        email: `qa-admin-${suffix}@example.invalid`,
        role: "admin",
        active: true,
        color: "green",
      })
    ).error,
  );
  const loginA = await a.auth.signInWithPassword({
    email: `qa-admin-${suffix}@example.invalid`,
    password,
  });
  assert.ifError(loginA.error);
  const tokenA = loginA.data.session!.access_token;
  const projects = await a.from("columns").select("*");
  assert.ifError(projects.error);
  assert.ok(projects.data!.some((c) => c.kind === "project"));
  assert.ok(projects.data!.some((c) => c.kind === "done"));
  const project = projects.data!.find((c) => c.kind === "project")!.id;
  const workspace = projects.data!.find((c) => c.id === project)!.workspace_id;
  const workspaces = await b.from("workspaces").select("id");
  assert.ok(
    workspaces.error || workspaces.data?.length === 0,
    "Unauthenticated workspace access",
  );
  const done = projects.data!.find(
    (c) => c.kind === "done" && c.workspace_id === workspace,
  )!.id;
  const member = {
    name: "QA Member",
    email: `qa-member-${suffix}@example.invalid`,
    password,
    role: "mitarbeiter",
    color: "mint",
    default_column_id: project,
    default_workspace_id: workspace,
    active: true,
  };
  const createdB = await request("/api/users", tokenA, "POST", member);
  assert.equal(createdB.status, 201, JSON.stringify(createdB.data));
  accounts.push(createdB.data.id);
  const savedProfile = await admin
    .from("profiles")
    .select("color,default_workspace_id,default_column_id")
    .eq("id", createdB.data.id)
    .single();
  assert.ifError(savedProfile.error);
  assert.equal(savedProfile.data.color, "mint");
  assert.equal(savedProfile.data.default_workspace_id, workspace);
  assert.equal(savedProfile.data.default_column_id, project);
  const invalidWorkspace = await request("/api/users", tokenA, "POST", {
    ...member,
    email: `qa-invalid-${suffix}@example.invalid`,
    default_workspace_id: randomUUID(),
  });
  assert.equal(invalidWorkspace.status, 400);
  assert.equal(
    invalidWorkspace.data.error,
    "Bitte Workspace und passendes Standardprojekt wählen.",
  );
  const loginB = await b.auth.signInWithPassword({
    email: member.email,
    password,
  });
  assert.ifError(loginB.error);
  const tokenB = loginB.data.session!.access_token;
  const visibleWorkspaces = await b.from("workspaces").select("id");
  assert.ifError(visibleWorkspaces.error);
  assert.ok(visibleWorkspaces.data!.some((w) => w.id === workspace));
  assert.equal(
    (await request("/api/users", tokenB, "POST", member)).status,
    403,
  );
  assert.equal((await request("/api/users", null, "POST", member)).status, 401);
  console.log(
    "PASS: real password login, admin account creation, employee admin-route denial",
  );
  const label = await b
    .from("labels")
    .insert({ name: `QA ${suffix.slice(0, 8)}`, color: "lavender" })
    .select()
    .single();
  assert.ifError(label.error);
  labelId = label.data.id;
  assert.equal(label.data.color, "lavender");
  const card = await b
    .from("cards")
    .insert({
      title: "QA integration card",
      column_id: project,
      project_id: project,
      assignee_id: createdB.data.id,
      label_ids: [labelId],
    })
    .select()
    .single();
  assert.ifError(card.error);
  cardId = card.data.id;
  let returnProject = project;
  for (const origin of projects.data!.filter(
    (c) => c.kind !== "done" && c.workspace_id === workspace,
  )) {
    if (origin.kind === "project") returnProject = origin.id;
    assert.ifError(
      (
        await b.rpc("move_card", {
          p_card: cardId,
          p_column: origin.id,
          p_before: null,
        })
      ).error,
    );
    const openCard = await b
      .from("cards")
      .select("*")
      .eq("id", cardId)
      .single();
    assert.ifError(openCard.error);
    assert.equal(openCard.data.column_id, origin.id);
    assert.equal(openCard.data.completed_at, null);
    // Two checks in flight must still produce one stable completion.
    const checks = await Promise.all([
      b.rpc("set_card_completed", { p_card: cardId, p_completed: true }),
      b.rpc("set_card_completed", { p_card: cardId, p_completed: true }),
    ]);
    checks.forEach((result) => assert.ifError(result.error));
    const completed = await b
      .from("cards")
      .select("*")
      .eq("id", cardId)
      .single();
    assert.ifError(completed.error);
    assert.equal(completed.data.column_id, done);
    assert.ok(completed.data.completed_at);
    assert.equal(completed.data.project_id, project);
    assert.ifError(
      (await b.rpc("set_card_completed", { p_card: cardId, p_completed: true }))
        .error,
    );
    const repeated = await b
      .from("cards")
      .select("*")
      .eq("id", cardId)
      .single();
    assert.deepEqual(repeated.data, completed.data);
  }
  assert.ifError(
    (await a.rpc("set_card_completed", { p_card: cardId, p_completed: false }))
      .error,
  );
  const reopened = await b.from("cards").select("*").eq("id", cardId).single();
  assert.ifError(reopened.error);
  assert.equal(reopened.data.column_id, returnProject);
  assert.equal(reopened.data.completed_at, null);
  assert.ifError(
    (await b.rpc("set_card_completed", { p_card: cardId, p_completed: true }))
      .error,
  );
  const doneCard = await b.from("cards").select("*").eq("id", cardId).single();
  assert.ok(doneCard.data.completed_at);
  assert.equal(doneCard.data.project_id, project);
  console.log(
    "PASS: every project and In Arbeit -> Fertig, concurrent/idempotent checks, manual movement, reopen to the last real project",
  );
  const employeeReview = await b
    .from("cards")
    .update({ reviewed_at: new Date().toISOString() })
    .eq("id", cardId);
  assert.ok(employeeReview.error);
  const adminReview = await a
    .from("cards")
    .update({ reviewed_at: new Date().toISOString() })
    .eq("id", cardId);
  assert.ifError(adminReview.error);
  console.log(
    "PASS: shared cards, custom labels, completion, stable project, admin-only read receipts",
  );
  let sawNotification = false;
  await b.realtime.setAuth(tokenB);
  const channel = b
    .channel(`qa-${suffix}`)
    .on(
      "postgres_changes",
      {
        event: "UPDATE",
        schema: "public",
        table: "access_revisions",
        filter: `id=eq.${createdB.data.id}`,
      },
      () => {
        sawNotification = true;
      },
    );
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error("Realtime replication readiness timeout")),
      20000,
    );
    channel
      .on("system", {}, (payload) => {
        if (
          payload.extension === "postgres_changes" &&
          payload.status === "ok"
        ) {
          clearTimeout(timer);
          resolve();
        }
      })
      .subscribe();
  });
  assert.ifError(
    (
      await a
        .from("comments")
        .insert({ card_id: cardId, body: "QA notification verification" })
    ).error,
  );
  for (let attempts = 0; attempts < 50 && !sawNotification; attempts++)
    await new Promise((r) => setTimeout(r, 300));
  assert.ok(sawNotification, "Realtime refresh signal was not received");
  const notifications = await b
    .from("notifications")
    .select("*")
    .eq("card_id", cardId);
  assert.ifError(notifications.error);
  assert.equal(notifications.data!.length, 1);
  const isolated = await a
    .from("notifications")
    .select("*")
    .eq("card_id", cardId);
  assert.equal(isolated.data!.length, 0);
  assert.ifError(
    (
      await b
        .from("notifications")
        .update({ seen_at: new Date().toISOString() })
        .eq("id", notifications.data![0].id)
    ).error,
  );
  await b.removeChannel(channel);
  console.log(
    "PASS: comments, live Realtime delivery, recipient isolation, mark seen",
  );
  assert.equal(
    (
      await request(`/api/users/${createdB.data.id}`, tokenA, "PATCH", {
        ...member,
        password: undefined,
        active: false,
      })
    ).status,
    200,
  );
  const revoked = await b.from("cards").select("*");
  assert.ifError(revoked.error);
  assert.equal(revoked.data!.length, 0);
  assert.equal(
    (
      await request(`/api/users/${aId}`, tokenA, "PATCH", {
        name: "QA Admin",
        email: `qa-admin-${suffix}@example.invalid`,
        role: "mitarbeiter",
        color: "green",
        default_column_id: null,
        active: true,
      })
    ).status,
    400,
  );
  console.log("PASS: immediate access revocation and self-demotion protection");
} finally {
  await a.removeAllChannels();
  await b.removeAllChannels();
  if (cardId)
    assert.ifError((await admin.from("cards").delete().eq("id", cardId)).error);
  if (labelId)
    assert.ifError(
      (await admin.from("labels").delete().eq("id", labelId)).error,
    );
  for (const id of accounts.reverse())
    assert.ifError((await admin.auth.admin.deleteUser(id)).error);
  console.log("Cleanup: only test-created cards, labels and accounts removed.");
}
