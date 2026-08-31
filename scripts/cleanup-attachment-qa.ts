import "dotenv/config";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createClient } from "@supabase/supabase-js";
import { removeAttachment } from "../src/attachments.js";
const fixture = JSON.parse(await readFile(".attachments-qa.json", "utf8")) as {
  users: string[];
  cards: string[];
};
const admin = createClient(
  process.env.SUPABASE_URL!,
  process.env.SUPABASE_SECRET_KEY!,
  { auth: { persistSession: false } },
);
for (const id of fixture.users) {
  assert.match(id, /^[0-9a-f-]{36}$/);
  const user = await admin.auth.admin.getUserById(id);
  assert.equal(user.error, null);
  assert.match(
    user.data.user!.email!,
    /^attachments-qa-[0-9a-f]{8}-[0-9]+@example\.com$/,
  );
}
for (const id of fixture.cards) {
  assert.match(id, /^[0-9a-f-]{36}$/);
  const card = await admin
    .from("cards")
    .select("created_by")
    .eq("id", id)
    .maybeSingle();
  assert.equal(card.error, null);
  if (card.data) assert.ok(fixture.users.includes(card.data.created_by));
  const items = await admin.from("attachments").select("id").eq("card_id", id);
  assert.equal(items.error, null);
  for (const item of items.data || []) await removeAttachment(admin, item.id);
  assert.equal((await admin.from("cards").delete().eq("id", id)).error, null);
}
for (const id of fixture.users)
  assert.equal((await admin.auth.admin.deleteUser(id)).error, null);
console.log(
  "Only the manifest's disposable attachment QA accounts/cards/files were removed.",
);
