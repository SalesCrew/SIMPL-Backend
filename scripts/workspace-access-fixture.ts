import "dotenv/config";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createClient } from "@supabase/supabase-js";
import { BUCKET, removeAttachment } from "../src/attachments.js";
const fixture = JSON.parse(await readFile(".workspace-access-qa.json", "utf8"));
assert.match(fixture.stamp, /^[a-f0-9]{8}$/);
const root = createClient(
  process.env.SUPABASE_URL!,
  process.env.SUPABASE_SECRET_KEY!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);
const action = process.argv[2];
const result = (r: { error: unknown }) => assert.equal(r.error, null);
for (const w of fixture.workspaces) {
  const row = await root
    .from("workspaces")
    .select("name")
    .eq("id", w.id)
    .single();
  result(row);
  assert.equal(row.data?.name, w.name);
  assert.ok(w.name.startsWith("Isolation QA " + fixture.stamp + " "));
}
if (action === "isolate-shared" || action === "open-shared") {
  result(
    await root
      .from("workspaces")
      .update({ isolated: action === "isolate-shared" })
      .eq("id", fixture.workspaces[3].id),
  );
  console.log("QA shared workspace permission changed.");
} else if (action === "live-api") {
  const user = fixture.users[1],
    card = fixture.cards[1],
    file = fixture.attachments[0];
  const api = "https://trello-plus-backend.vercel.app/api";
  for (const [path, method, body, status] of [
    [
      "/attachments",
      "POST",
      { card_id: card, filename: "denied.txt", size_bytes: 1 },
      404,
    ],
    ["/attachments/" + file, "DELETE", undefined, 204],
    ["/cards/" + card, "DELETE", undefined, 404],
  ] as const) {
    const response = await fetch(api + path, {
      method,
      headers: {
        Authorization: "Bearer " + user.token,
        "Content-Type": "application/json",
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    assert.equal(response.status, status);
  }
  const item = await root
    .from("attachments")
    .select("object_path")
    .eq("id", file)
    .single();
  result(item);
  result(await root.storage.from(BUCKET).download(item.data!.object_path));
  console.log(
    "PASS deployed backend denies hidden cards/files; idempotent hidden deletion did not remove data.",
  );
} else if (action === "cleanup") {
  for (const user of fixture.users) {
    const found = await root.auth.admin.getUserById(user.id);
    result(found);
    assert.equal(found.data.user?.email, user.email);
    assert.ok(user.email.startsWith("isolation-qa-" + fixture.stamp + "-"));
  }
  const cards = await root
    .from("cards")
    .select("id")
    .in(
      "workspace_id",
      fixture.workspaces.map((w: { id: string }) => w.id),
    );
  result(cards);
  const ids = cards.data!.map((c) => c.id);
  if (ids.length) {
    const files = await root
      .from("attachments")
      .select("id")
      .in("card_id", ids);
    result(files);
    for (const file of files.data!) await removeAttachment(root, file.id);
    result(await root.from("cards").delete().in("id", ids));
  }
  for (const user of [...fixture.users].reverse())
    result(await root.auth.admin.deleteUser(user.id));
  console.log(
    "Removed only the isolated QA fixture's cards, files and accounts. Empty workspaces await scoped SQL cleanup.",
  );
} else throw new Error("Use isolate-shared, open-shared, live-api or cleanup.");
