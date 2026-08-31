import "dotenv/config";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { writeFile } from "node:fs/promises";
import { deflateSync } from "node:zlib";
import { createClient } from "@supabase/supabase-js";
import request from "supertest";
import app from "../server.js";
import {
  BUCKET,
  cleanupAttachments,
  removeAttachment,
} from "../src/attachments.js";

const url = process.env.SUPABASE_URL!;
const key = process.env.SUPABASE_PUBLISHABLE_KEY!;
const admin = createClient(url, process.env.SUPABASE_SECRET_KEY!, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const client = () =>
  createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
const stamp = randomUUID().slice(0, 8);
const users: string[] = [];
const cards: string[] = [];
let keep = false;
const ok = (name: string) => console.log("PASS " + name);
function result<T extends { data: unknown; error: unknown }>(
  value: T,
): NonNullable<T["data"]> {
  assert.equal(value.error, null);
  return value.data as NonNullable<T["data"]>;
}
// Generated, non-user screenshot fixture. PNG structure + CRC keeps image decoding realistic.
function pngFixture() {
  const width = 800,
    height = 450;
  const rows = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y++)
    for (let x = 0; x < width; x++) {
      const panel = x > 35 && x < 765 && y > 35 && y < 415;
      const tile = x > 65 && x < 735 && y > 120 && y < 210;
      const green = x > 65 && x < 390 && y > 65 && y < 90;
      const rgb = green
        ? [123, 168, 141]
        : tile
          ? [233, 242, 235]
          : panel
            ? [255, 255, 255]
            : [246, 247, 244];
      const offset = y * (width * 3 + 1) + 1 + x * 3;
      rows.set(rgb, offset);
    }
  const chunk = (name: string, data: Buffer) => {
    const type = Buffer.from(name),
      payload = Buffer.concat([type, data]);
    let crc = 0xffffffff;
    for (const b of payload) {
      crc ^= b;
      for (let bit = 0; bit < 8; bit++)
        crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
    }
    const header = Buffer.alloc(4),
      trailer = Buffer.alloc(4);
    header.writeUInt32BE(data.length);
    trailer.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
    return Buffer.concat([header, payload, trailer]);
  };
  const dimensions = Buffer.alloc(13);
  dimensions.writeUInt32BE(width);
  dimensions.writeUInt32BE(height, 4);
  dimensions[8] = 8;
  dimensions[9] = 2;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", dimensions),
    chunk("IDAT", deflateSync(rows)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}
async function account(provision = true) {
  const email = `attachments-qa-${stamp}-${users.length}@example.com`;
  const password = randomUUID() + "!Aa8";
  const auth = result(
    await admin.auth.admin.createUser({ email, password, email_confirm: true }),
  );
  const id = auth.user!.id;
  users.push(id);
  if (provision)
    result(
      await admin.from("profiles").insert({
        id,
        email,
        name: "Anhänge QA",
        role: "mitarbeiter",
        color: "sage",
        active: true,
        default_workspace_id: project.workspace_id,
        default_column_id: project.id,
      }),
    );
  const db = client();
  const signed = result(await db.auth.signInWithPassword({ email, password }));
  return { db, id, email, password, token: signed.session!.access_token };
}
const project = result(
  await admin
    .from("columns")
    .select("id,workspace_id")
    .eq("kind", "project")
    .limit(1)
    .single(),
);
async function api(
  token: string,
  method: "post" | "delete",
  path: string,
  body?: unknown,
  expected = 200,
) {
  const response = await request(process.env.TEST_ATTACHMENT_API_URL || app)
    [method]("/api" + path)
    .set("Authorization", "Bearer " + token)
    .send(body as object);
  assert.equal(
    response.status,
    expected,
    `${method} ${path}: ${JSON.stringify(response.body)}`,
  );
  return response.body;
}
try {
  const owner = await account();
  const teammate = await account();
  const outsider = await account(false);
  const card = result(
    await owner.db
      .from("cards")
      .insert({
        title: "Anhänge QA – Screenshot & Dateien",
        description:
          "Temporäre End-to-End-Prüfung. Wird nach dem Test entfernt.",
        column_id: project.id,
        project_id: project.id,
      })
      .select("id")
      .single(),
  );
  cards.push(card.id);
  const reserve = (filename: string, size: number) =>
    api(
      owner.token,
      "post",
      "/attachments",
      { card_id: card.id, filename, size_bytes: size },
      201,
    );
  const png = pngFixture();
  const image = await reserve("Screenshot-Test.png", png.length);
  result(
    await owner.db.storage.from(BUCKET).upload(image.object_path, png, {
      contentType: "image/png",
      upsert: false,
    }),
  );
  assert.ok(
    (await teammate.db.storage.from(BUCKET).download(image.object_path)).error,
  );
  assert.ok(
    (
      await owner.db.from("attachments").insert({
        card_id: card.id,
        uploaded_by: owner.id,
        filename: "x.txt",
        mime_type: "text/plain",
        size_bytes: 1,
      })
    ).error,
  );
  assert.ok(
    (
      await owner.db
        .from("attachments")
        .update({ status: "ready" })
        .eq("id", image.id)
    ).error,
  );
  assert.ok(
    (
      await owner.db.storage
        .from(BUCKET)
        .upload(card.id + "/" + randomUUID(), png, { contentType: "image/png" })
    ).error,
  );
  assert.ok(
    (
      await teammate.db.storage
        .from(BUCKET)
        .upload(image.object_path, png, { contentType: "image/png" })
    ).error,
  );
  ok(
    "pending file isolation, forged paths, metadata writes and another uploader denied",
  );
  const ready = await api(
    owner.token,
    "post",
    `/attachments/${image.id}/complete`,
  );
  assert.equal(ready.status, "ready");
  await api(owner.token, "post", `/attachments/${image.id}/complete`);
  const downloaded = await request(process.env.TEST_ATTACHMENT_API_URL || app)
    .get(`/api/attachments/${image.id}/download`)
    .set("Authorization", `Bearer ${teammate.token}`);
  assert.equal(downloaded.status, 200);
  assert.equal(downloaded.body.length, png.length);
  assert.match(downloaded.headers["cache-control"], /private.*no-store/);
  assert.ok(
    (await teammate.db.storage.from(BUCKET).download(image.object_path)).error,
  );
  assert.ok(
    (
      await owner.db.storage.from(BUCKET).upload(image.object_path, png, {
        contentType: "image/png",
        upsert: true,
      })
    ).error,
  );
  assert.ok(
    (await owner.db.storage.from(BUCKET).createSignedUrl(image.object_path, 60))
      .error,
  );
  assert.ok(
    (await client().storage.from(BUCKET).download(image.object_path)).error,
  );
  assert.ok(
    (await outsider.db.storage.from(BUCKET).download(image.object_path)).error,
  );
  const listed = await owner.db.storage.from(BUCKET).list(card.id);
  assert.ok(listed.error || listed.data?.length === 0);
  ok(
    "publish is idempotent; team download works; overwrite, signed links, listing, anonymous/unprovisioned access denied",
  );
  await api(
    outsider.token,
    "post",
    "/attachments",
    { card_id: card.id, filename: "x.txt", size_bytes: 5 },
    403,
  );
  result(
    await admin
      .from("profiles")
      .update({ active: false })
      .eq("id", teammate.id),
  );
  assert.ok(
    (await teammate.db.storage.from(BUCKET).download(image.object_path)).error,
  );
  assert.equal(
    (
      await request(process.env.TEST_ATTACHMENT_API_URL || app)
        .get(`/api/attachments/${image.id}/download`)
        .set("Authorization", `Bearer ${teammate.token}`)
    ).status,
    403,
  );
  await api(
    teammate.token,
    "delete",
    `/attachments/${image.id}`,
    undefined,
    403,
  );
  result(
    await admin.from("profiles").update({ active: true }).eq("id", teammate.id),
  );
  ok(
    "deactivation immediately blocks downloads and deletion with existing tokens",
  );
  assert.ok((await owner.db.from("cards").delete().eq("id", card.id)).error);
  const forged = await reserve("fake.png", 17);
  result(
    await owner.db.storage
      .from(BUCKET)
      .upload(forged.object_path, Buffer.from("not a real image!"), {
        contentType: "image/png",
      }),
  );
  await api(
    owner.token,
    "post",
    `/attachments/${forged.id}/complete`,
    undefined,
    400,
  );
  assert.ok((await admin.storage.from(BUCKET).info(forged.object_path)).error);
  const wrongSize = await reserve("wrong.txt", 4);
  result(
    await owner.db.storage
      .from(BUCKET)
      .upload(wrongSize.object_path, Buffer.from("five!"), {
        contentType: "text/plain",
      }),
  );
  await api(
    owner.token,
    "post",
    `/attachments/${wrongSize.id}/complete`,
    undefined,
    400,
  );
  await api(
    owner.token,
    "post",
    "/attachments",
    { card_id: card.id, filename: "../x.svg", size_bytes: 10 },
    400,
  );
  await api(
    owner.token,
    "post",
    "/attachments",
    { card_id: card.id, filename: "x.txt", size_bytes: 524288001 },
    400,
  );
  ok(
    "invalid signatures, size mismatches, unsafe names and oversized reservations rejected and cleaned",
  );
  const cancel = await reserve("cancel.txt", 4);
  result(
    await owner.db.storage
      .from(BUCKET)
      .upload(cancel.object_path, Buffer.from("test"), {
        contentType: "text/plain",
      }),
  );
  await api(owner.token, "delete", `/attachments/${cancel.id}`, undefined, 204);
  await api(owner.token, "delete", `/attachments/${cancel.id}`, undefined, 204);
  assert.ok((await admin.storage.from(BUCKET).info(cancel.object_path)).error);
  assert.ok(
    (
      await owner.db.storage
        .from(BUCKET)
        .upload(cancel.object_path, Buffer.from("test"), {
          contentType: "text/plain",
        })
    ).error,
  );
  const expired = await reserve("expired.txt", 4);
  result(
    await owner.db.storage
      .from(BUCKET)
      .upload(expired.object_path, Buffer.from("test"), {
        contentType: "text/plain",
      }),
  );
  result(
    await admin
      .from("attachments")
      .update({ expires_at: new Date(Date.now() - 60000).toISOString() })
      .eq("id", expired.id),
  );
  await cleanupAttachments(admin, owner.id);
  assert.ok((await admin.storage.from(BUCKET).info(expired.object_path)).error);
  ok(
    "cancel, duplicate delete and expired reservation cleanup remove files and block later upload",
  );
  const concurrent = await Promise.all(
    Array.from({ length: 21 }, (_, i) =>
      request(process.env.TEST_ATTACHMENT_API_URL || app)
        .post("/api/attachments")
        .set("Authorization", "Bearer " + owner.token)
        .send({ card_id: card.id, filename: `limit-${i}.txt`, size_bytes: 4 }),
    ),
  );
  assert.equal(concurrent.filter((r) => r.status === 201).length, 19);
  assert.equal(concurrent.filter((r) => r.status === 409).length, 2);
  for (const item of concurrent.filter((r) => r.status === 201))
    await removeAttachment(admin, item.body.id);
  ok("21 concurrent reservations cannot bypass the 20-file cap");
  const textFile = Buffer.from(
    "Prüfnotiz: Anhänge, Downloads und private Zugriffe funktionieren.\n",
  );
  const note = await reserve("Prüfnotiz.txt", textFile.length);
  result(
    await owner.db.storage
      .from(BUCKET)
      .upload(note.object_path, textFile, { contentType: "text/plain" }),
  );
  await api(owner.token, "post", `/attachments/${note.id}/complete`);
  if (process.argv.includes("--keep-ui")) {
    await writeFile(
      ".attachments-qa.json",
      JSON.stringify({
        id: owner.id,
        email: owner.email,
        password: owner.password,
        cardId: card.id,
        imageId: image.id,
        noteId: note.id,
        users,
        cards,
      }),
    );
    await writeFile(".attachment-fixture.png", png);
    keep = true;
    console.log(
      "UI fixtures prepared; credentials kept in ignored .attachments-qa.json (not printed).",
    );
  } else {
    await api(teammate.token, "delete", `/cards/${card.id}`, undefined, 204);
    assert.ok((await admin.storage.from(BUCKET).info(image.object_path)).error);
    assert.ok((await admin.storage.from(BUCKET).info(note.object_path)).error);
    ok("card deletion removes all files and metadata through Storage API");
  }
} finally {
  if (!keep) {
    for (const cardId of cards) {
      const items = result(
        await admin.from("attachments").select("id").eq("card_id", cardId),
      );
      for (const item of items || []) await removeAttachment(admin, item.id);
      result(await admin.from("cards").delete().eq("id", cardId));
    }
    for (const user of users.reverse())
      result(await admin.auth.admin.deleteUser(user));
    console.log("Disposable cards, files and accounts removed.");
  }
}
