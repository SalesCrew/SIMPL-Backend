import "dotenv/config";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { Upload, DefaultHttpStack } from "tus-js-client";
import { createClient } from "@supabase/supabase-js";
import request from "supertest";
import app from "../server.js";
import { BUCKET, removeAttachment } from "../src/attachments.js";
import { MAX_FILE_SIZE } from "../src/attachment-validation.js";

const url = process.env.SUPABASE_URL!;
const key = process.env.SUPABASE_PUBLISHABLE_KEY!;
const options = { auth: { persistSession: false, autoRefreshToken: false } };
const admin = createClient(url, process.env.SUPABASE_SECRET_KEY!, options);
const db = createClient(url, key, options);
const endpoint =
  url.replace(".supabase.co", ".storage.supabase.co") +
  "/storage/v1/upload/resumable";
const users: string[] = [],
  cards: string[] = [],
  uploads: string[] = [];
const completedUploads = new Set<string>();
// Keep this development-only client pinned to the same version as the frontend.
function checked<T extends { data: unknown; error: unknown }>(
  value: T,
): NonNullable<T["data"]> {
  assert.equal(value.error, null);
  return value.data as NonNullable<T["data"]>;
}
const pass = (message: string) => console.log("PASS " + message);
let token = "";
const headers = () => ({
  Authorization: `Bearer ${token}`,
  apikey: key,
  "Tus-Resumable": "1.0.0",
  "x-upsert": "false",
});
const tusRequest = (target: string, init: RequestInit) =>
  fetch(target, { ...init, signal: AbortSignal.timeout(120000) });
try {
  const project = checked(
    await admin
      .from("columns")
      .select("id,workspace_id")
      .eq("kind", "project")
      .limit(1)
      .single(),
  )!;
  const email = `large-files-qa-${randomUUID()}@example.com`,
    password = randomUUID() + "!Aa8";
  const account = checked(
    await admin.auth.admin.createUser({ email, password, email_confirm: true }),
  );
  const actor = account.user!.id;
  users.push(actor);
  checked(
    await admin.from("profiles").insert({
      id: actor,
      email,
      name: "Large files QA",
      role: "mitarbeiter",
      active: true,
      color: "sage",
      default_workspace_id: project.workspace_id,
      default_column_id: project.id,
    }),
  );
  token = checked(await db.auth.signInWithPassword({ email, password }))
    .session!.access_token;
  const card = checked(
    await db
      .from("cards")
      .insert({
        title: "Large upload QA (temporary)",
        column_id: project.id,
        project_id: project.id,
      })
      .select("id")
      .single(),
  )!;
  cards.push(card.id);
  const reserve = async (size: number, comment = false) => {
    const response = await request(app)
      .post("/api/attachments")
      .set("Authorization", `Bearer ${token}`)
      .send({
        card_id: card.id,
        filename: "test-export.bin",
        size_bytes: size,
        ...(comment ? { comment_draft_id: randomUUID() } : {}),
      });
    assert.equal(response.status, 201, JSON.stringify(response.body));
    assert.ok(
      Date.parse(response.body.expires_at) - Date.now() > 23 * 60 * 60 * 1000,
    );
    return response.body;
  };
  const create = async (
    item: { object_path: string; mime_type: string },
    size: number,
    authHeaders = headers(),
  ) => {
    const metadata = Object.entries({
      bucketName: BUCKET,
      objectName: item.object_path,
      contentType: item.mime_type,
      cacheControl: "no-store",
    })
      .map(([k, v]) => `${k} ${Buffer.from(v).toString("base64")}`)
      .join(",");
    return tusRequest(endpoint, {
      method: "POST",
      headers: {
        ...authHeaders,
        "Upload-Length": String(size),
        "Upload-Metadata": metadata,
      },
    });
  };
  const over = await request(app)
    .post("/api/attachments")
    .set("Authorization", `Bearer ${token}`)
    .send({
      card_id: card.id,
      filename: "oversize.bin",
      size_bytes: MAX_FILE_SIZE + 1,
    });
  assert.equal(over.status, 400);
  const item = await reserve(MAX_FILE_SIZE, true);
  const storageOver = await create(item, MAX_FILE_SIZE + 1);
  assert.equal(
    storageOver.status,
    413,
    `Storage must reject >500 MB, got ${storageOver.status}`,
  );
  pass("API and Storage reject 500 MB + 1 byte");
  const boundary = await create(item, MAX_FILE_SIZE);
  assert.equal(
    boundary.status,
    201,
    `500 MB TUS creation: ${boundary.status} ${await boundary.clone().text()}`,
  );
  const boundaryUrl = new URL(boundary.headers.get("Location")!, endpoint).href;
  uploads.push(boundaryUrl);
  pass("Storage accepts exactly 500 MB; metadata expires after 24 hours");
  const forged = await create(
    { ...item, object_path: `${card.id}/${randomUUID()}` },
    1,
  );
  assert.ok(
    forged.status >= 400,
    "Unreserved object paths must be denied by TUS",
  );
  // TUS HEAD is a progress probe, not a file read; test anonymous byte access/write instead.
  const anonymousGet = await tusRequest(boundaryUrl, {
    method: "GET",
    headers: { apikey: key, "Tus-Resumable": "1.0.0" },
  });
  assert.ok(anonymousGet.status >= 400, "TUS URLs must not serve file bytes");
  const anonymousPatch = await tusRequest(boundaryUrl, {
    method: "PATCH",
    headers: {
      apikey: key,
      "Tus-Resumable": "1.0.0",
      "Upload-Offset": "0",
      "Content-Type": "application/offset+octet-stream",
    },
    body: Buffer.from([65]),
  });
  assert.ok(
    anonymousPatch.status >= 400,
    "TUS URLs must not permit anonymous writes",
  );
  checked(
    await admin.from("profiles").update({ active: false }).eq("id", actor),
  );
  const revokedCreate = await create(item, MAX_FILE_SIZE);
  assert.ok(
    revokedCreate.status >= 400,
    "Revoked users cannot create TUS uploads",
  );
  const revokedPatch = await tusRequest(boundaryUrl, {
    method: "PATCH",
    headers: {
      ...headers(),
      "Upload-Offset": "0",
      "Content-Type": "application/offset+octet-stream",
    },
    body: Buffer.from([65]),
  });
  assert.ok(
    revokedPatch.status >= 400,
    "Revoked users cannot continue old TUS URLs",
  );
  checked(
    await admin.from("profiles").update({ active: true }).eq("id", actor),
  );
  pass(
    "TUS denies forged paths, anonymous URLs and revoked users with existing tokens",
  );

  // Normal runs transfer 13 MB. --full transfers exactly 500 MB using only a
  // single reusable 6 MB buffer, never allocating the entire file in memory.
  const full = process.argv.includes("--full");
  const size = full ? MAX_FILE_SIZE : 13 * 1024 * 1024;
  const target = await reserve(size, true);
  const chunk = Buffer.alloc(6 * 1024 * 1024, 65);
  const stack = new DefaultHttpStack({});
  let droppedAck = false,
    resumed = false,
    retries = 0,
    nextProgress = 60 * 1024 * 1024;
  await new Promise<void>((resolve, reject) => {
    const upload = new Upload(Buffer.alloc(1), {
      endpoint,
      chunkSize: chunk.length,
      uploadSize: size,
      uploadDataDuringCreation: true,
      storeFingerprintForResuming: false,
      retryDelays: [0, 1000, 3000, 5000, 10000],
      headers: { apikey: key, "x-upsert": "false" },
      metadata: {
        bucketName: BUCKET,
        objectName: target.object_path,
        contentType: target.mime_type,
        cacheControl: "no-store",
      },
      fileReader: {
        openFile: async () => ({
          size,
          slice: async (start, end) => {
            const value = chunk.subarray(0, Math.min(end, size) - start);
            // TUS custom sources use .size for Content-Length and EOF checks.
            return {
              value: Object.assign(value, { size: value.length }),
              done: end >= size,
            };
          },
          close: () => {},
        }),
      },
      httpStack: {
        getName: () => stack.getName(),
        createRequest(method, requestUrl) {
          const req = stack.createRequest(method, requestUrl);
          const send = req.send.bind(req);
          req.send = async (body) => {
            const response = await send(body);
            // Lose one acknowledgement after the server accepted the chunk.
            // TUS must recover the true offset without duplicating bytes.
            if (
              method === "PATCH" &&
              response.getStatus() === 204 &&
              !droppedAck
            ) {
              droppedAck = true;
              throw new Error(
                "QA simulated connection drop after accepted chunk",
              );
            }
            if (method === "HEAD" && droppedAck && response.getStatus() === 200)
              resumed = true;
            return response;
          };
          return req;
        },
      },
      onBeforeRequest: async (req) => {
        token = checked(await db.auth.getSession()).session!.access_token;
        req.setHeader("Authorization", `Bearer ${token}`);
      },
      onShouldRetry(error) {
        const status = error.originalResponse?.getStatus() || 0;
        const retry =
          status === 0 ||
          status === 408 ||
          status === 409 ||
          status === 423 ||
          status === 429 ||
          status >= 500;
        if (retry) {
          retries++;
          console.log(
            `Resuming interrupted upload (status ${status || "network"})…`,
          );
        }
        return retry;
      },
      onUploadUrlAvailable: () => {
        if (upload.url) uploads.push(upload.url);
      },
      onChunkComplete: (_chunk, offset) => {
        if (offset === size || offset >= nextProgress) {
          console.log(
            `Uploaded ${Math.round(offset / 1024 / 1024)} / ${Math.round(size / 1024 / 1024)} MB`,
          );
          nextProgress = offset + 60 * 1024 * 1024;
        }
      },
      onSuccess: () => {
        if (upload.url) completedUploads.add(upload.url);
        resolve();
      },
      onError: (error) =>
        reject(
          new Error(
            `TUS upload failed: ${"originalResponse" in error ? error.originalResponse?.getStatus() : "network"}`,
          ),
        ),
    });
    upload.start();
  });
  assert.ok(droppedAck && resumed && retries > 0);
  pass(
    "Pinned TUS client recovers a lost chunk acknowledgement and resumes from the server offset",
  );
  const complete = await request(app)
    .post(`/api/attachments/${target.id}/complete`)
    .set("Authorization", `Bearer ${token}`);
  assert.equal(complete.status, 200, JSON.stringify(complete.body));
  assert.equal(complete.body.status, "ready");
  assert.equal(complete.body.mime_type, "application/octet-stream");
  assert.equal(
    checked(await db.storage.from(BUCKET).info(target.object_path))!.size,
    size,
  );
  // Authenticate and stream a small download range; do not buffer a 500 MB blob.
  const read = await fetch(
    `${url}/storage/v1/object/authenticated/${BUCKET}/${target.object_path}`,
    {
      headers: {
        Authorization: `Bearer ${token}`,
        apikey: key,
        Range: "bytes=0-15",
      },
    },
  );
  assert.equal(read.status, 206);
  assert.deepEqual(Buffer.from(await read.arrayBuffer()), Buffer.alloc(16, 65));
  const anonymous = await fetch(
    `${url}/storage/v1/object/authenticated/${BUCKET}/${target.object_path}`,
    { headers: { apikey: key, Range: "bytes=0-15" } },
  );
  assert.notEqual(anonymous.status, 200);
  assert.notEqual(anonymous.status, 206);
  pass(
    `${size / 1024 / 1024} MB upload/finalization/download succeeds; anonymous access denied`,
  );
  checked(
    await db.from("comments").insert({
      card_id: card.id,
      body: "Large upload QA",
      attachment_ids: [target.id],
    }),
  );
  assert.ok(
    checked(
      await admin
        .from("attachments")
        .select("comment_id")
        .eq("id", target.id)
        .single(),
    )!.comment_id,
  );
  pass("Large attachment publishes atomically with its comment");
} finally {
  // Only IDs created by this run; no user files/accounts are touched.
  for (const id of users)
    checked(await admin.from("profiles").update({ active: true }).eq("id", id));
  for (const upload of uploads) {
    if (completedUploads.has(upload)) continue; // Published object is removed through Storage below.
    const response = await tusRequest(upload, {
      method: "DELETE",
      headers: headers(),
    });
    if (![204, 404, 410].includes(response.status))
      console.log(
        `Partial upload termination status ${response.status}; server expiry applies.`,
      );
  }
  for (const id of cards) {
    for (const item of checked(
      await admin.from("attachments").select("id").eq("card_id", id),
    ) || [])
      await removeAttachment(admin, item.id);
    checked(await admin.from("cards").delete().eq("id", id));
  }
  for (const id of users) checked(await admin.auth.admin.deleteUser(id));
  console.log("Disposable large-upload fixtures removed.");
}
