import "dotenv/config";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import request from "supertest";
import app from "../server.js";
import {
  BUCKET,
  cleanupAttachments,
  removeAttachment,
} from "../src/attachments.js";

const options = { auth: { persistSession: false, autoRefreshToken: false } };
const root = createClient(
  process.env.SUPABASE_URL!,
  process.env.SUPABASE_SECRET_KEY!,
  options,
);
const client = () =>
  createClient(
    process.env.SUPABASE_URL!,
    process.env.SUPABASE_PUBLISHABLE_KEY!,
    options,
  );
function result<T extends { data: unknown; error: unknown }>(
  value: T,
): NonNullable<T["data"]> {
  assert.equal(value.error, null, JSON.stringify(value.error));
  return value.data as NonNullable<T["data"]>;
}
const stamp = randomUUID().slice(0, 8);
const users: string[] = [],
  cards: string[] = [];
const sessions: { id: string; db: ReturnType<typeof client>; card: string }[] =
  [];
const project = result(
  await root
    .from("columns")
    .select("id,workspace_id")
    .eq("kind", "project")
    .limit(1)
    .single(),
);
async function account(provision = true) {
  const email = `comment-files-qa-${stamp}-${users.length}@example.com`,
    password = randomUUID() + "!Aa8";
  const auth = result(
    await root.auth.admin.createUser({ email, password, email_confirm: true }),
  );
  const id = auth.user!.id;
  users.push(id);
  if (provision)
    result(
      await root
        .from("profiles")
        .insert({
          id,
          email,
          name: "Comment files QA",
          role: "mitarbeiter",
          active: true,
          color: "sage",
          default_workspace_id: project.workspace_id,
          default_column_id: project.id,
        }),
    );
  const db = client();
  const signed = result(await db.auth.signInWithPassword({ email, password }));
  return { id, db, token: signed.session!.access_token };
}
const pass = (text: string) => console.log("PASS " + text);
try {
  const owner = await account(),
    teammate = await account(),
    outsider = await account(false);
  async function newCard() {
    const card = result(
      await owner.db
        .from("cards")
        .insert({
          title: "Comment files QA " + stamp,
          column_id: project.id,
          project_id: project.id,
          assignee_id: teammate.id,
        })
        .select("*")
        .single(),
    );
    cards.push(card.id);
    return card;
  }
  const card = await newCard(),
    otherCard = await newCard();
  async function upload(name: string, bytes: Buffer, cardId = card.id) {
    const reservation = await request(app)
      .post("/api/attachments")
      .set("Authorization", "Bearer " + owner.token)
      .send({
        card_id: cardId,
        filename: name,
        size_bytes: bytes.length,
        comment_draft_id: randomUUID(),
      });
    assert.equal(reservation.status, 201, JSON.stringify(reservation.body));
    const item = reservation.body;
    result(
      await owner.db.storage
        .from(BUCKET)
        .upload(item.object_path, bytes, { contentType: item.mime_type }),
    );
    const complete = await request(app)
      .post(`/api/attachments/${item.id}/complete`)
      .set("Authorization", "Bearer " + owner.token);
    assert.equal(complete.status, 200, JSON.stringify(complete.body));
    return complete.body;
  }
  const png = await upload(
    "Screenshot.png",
    Buffer.from(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6ZFAAAAAASUVORK5CYII=",
      "base64",
    ),
  );
  const pdf = await upload("Report.pdf", Buffer.from("%PDF-1.4\n%%EOF"));
  const excel = await upload(
    "Forecast.xlsx",
    Buffer.from([80, 75, 5, 6, ...Array(18).fill(0)]),
  );
  const arbitrary = await upload(
    "Drawing.custom",
    Buffer.from([0, 1, 255, 42]),
  );
  assert.equal(arbitrary.mime_type, "application/octet-stream");
  for (const viewer of [teammate.db, outsider.db, client()]) {
    const rows = await viewer.from("attachments").select("id").eq("id", png.id);
    assert.ok(rows.error || !rows.data?.length);
    assert.ok(
      (await viewer.storage.from(BUCKET).download(png.object_path)).error,
    );
  }
  result(await owner.db.storage.from(BUCKET).download(png.object_path));
  pass("PNG, PDF, Excel and opaque files upload; unsent files are private");
  const insert = (
    db: typeof owner.db,
    ids: string[],
    cardId = card.id,
    body = "",
  ) =>
    db
      .from("comments")
      .insert({ card_id: cardId, body, attachment_ids: ids })
      .select("*")
      .single();
  assert.ok((await insert(teammate.db, [png.id])).error);
  assert.ok((await insert(owner.db, [png.id], otherCard.id)).error);
  assert.ok((await insert(owner.db, [png.id, png.id])).error);
  assert.ok((await insert(owner.db, [])).error);
  pass(
    "foreign-owner, cross-card, duplicate and empty-message submissions rejected",
  );
  const sessionId = randomUUID();
  sessions.push({ id: sessionId, db: owner.db, card: card.id });
  result(
    await owner.db.rpc("card_edit_session", {
      p_session: sessionId,
      p_operation: "begin",
      p_card: card.id,
    }),
  );
  result(
    await owner.db.rpc("card_edit_session", {
      p_session: sessionId,
      p_operation: "mutate",
      p_card: card.id,
      p_action: {
        type: "comment.create",
        card_id: card.id,
        body: "",
        attachments: [png, pdf, excel, arbitrary],
      },
    }),
  );
  const message = result(
    await owner.db.from("comments").select("*").eq("card_id", card.id).single(),
  );
  assert.equal(message.body, "");
  assert.equal(message.attachment_ids.length, 4);
  for (const file of [png, pdf, excel, arbitrary]) {
    const metadata = result(
      await teammate.db
        .from("attachments")
        .select("*")
        .eq("id", file.id)
        .single(),
    );
    assert.equal(metadata.comment_id, message.id);
    assert.equal(metadata.comment_draft_id, null);
    result(await teammate.db.storage.from(BUCKET).download(file.object_path));
    assert.ok(
      (await outsider.db.storage.from(BUCKET).download(file.object_path)).error,
    );
    assert.ok(
      (await client().storage.from(BUCKET).download(file.object_path)).error,
    );
  }
  const notification = result(
    await teammate.db
      .from("notifications")
      .select("body")
      .eq("comment_id", message.id)
      .single(),
  );
  assert.ok(notification.body.includes("4"));
  assert.ok((await insert(owner.db, [png.id])).error);
  pass(
    "atomic attachment-only message, teammate downloads, notification and relink denial",
  );
  const discardPublished = await request(app)
    .delete(`/api/attachments/${png.id}?draft=1`)
    .set("Authorization", "Bearer " + owner.token);
  assert.equal(discardPublished.status, 204);
  result(await teammate.db.storage.from(BUCKET).download(png.object_path));
  pass("draft cleanup cannot remove a message file that was already published");
  result(
    await root.from("profiles").update({ active: false }).eq("id", teammate.id),
  );
  assert.ok(
    (await teammate.db.storage.from(BUCKET).download(png.object_path)).error,
  );
  result(
    await root.from("profiles").update({ active: true }).eq("id", teammate.id),
  );
  pass("deactivation immediately blocks file bytes with the existing token");
  result(
    await owner.db.rpc("card_edit_session", {
      p_session: sessionId,
      p_operation: "close",
      p_card: card.id,
    }),
  );
  result(
    await owner.db.rpc("card_edit_session", {
      p_session: sessionId,
      p_operation: "undo",
      p_card: card.id,
    }),
  );
  assert.equal(
    result(await root.from("comments").select("id").eq("id", message.id))
      .length,
    0,
  );
  await cleanupAttachments(root, undefined, card.id);
  for (const file of [png, pdf, excel, arbitrary])
    assert.ok((await root.storage.from(BUCKET).info(file.object_path)).error);
  pass(
    "undo removes message and all associated blobs without leaking card attachments",
  );
  const stale = await upload("Expired.txt", Buffer.from("draft"));
  result(
    await root
      .from("attachments")
      .update({ expires_at: new Date(Date.now() - 1000).toISOString() })
      .eq("id", stale.id),
  );
  assert.ok((await insert(owner.db, [stale.id])).error);
  await cleanupAttachments(root, undefined, card.id);
  assert.ok((await root.storage.from(BUCKET).info(stale.object_path)).error);
  pass("expired ready drafts cannot be sent and are cleaned via Storage API");
  const draft = randomUUID();
  for (let i = 0; i < 11; i++) {
    const reservation = await request(app)
      .post("/api/attachments")
      .set("Authorization", "Bearer " + owner.token)
      .send({
        card_id: card.id,
        filename: `Limit-${i}.txt`,
        size_bytes: 1,
        comment_draft_id: draft,
      });
    assert.equal(reservation.status, i < 10 ? 201 : 409);
  }
  pass("server enforces ten files per draft regardless of frontend controls");
} finally {
  for (const session of sessions)
    await session.db.rpc("card_edit_session", {
      p_session: session.id,
      p_operation: "discard",
      p_card: session.card,
    });
  for (const id of cards) {
    for (const item of result(
      await root.from("attachments").select("id").eq("card_id", id),
    ))
      await removeAttachment(root, item.id);
    result(await root.from("cards").delete().eq("id", id));
  }
  for (const id of users.reverse())
    result(await root.auth.admin.deleteUser(id));
  console.log("Removed only this run's disposable accounts, cards and files.");
}
