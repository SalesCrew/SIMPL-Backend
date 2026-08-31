import {
  Router,
  type Request,
  type Response,
  type NextFunction,
} from "express";
import type { SupabaseClient } from "@supabase/supabase-js";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { randomUUID } from "node:crypto";
import { z } from "zod";
import {
  MAX_PREVIEW_SIZE,
  validateFile,
  validFileBytes,
} from "./attachment-validation.js";

export const BUCKET = "card-attachments";
export class AttachmentError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message);
  }
}
const idSchema = z.string().uuid();
const inputSchema = z.object({
  card_id: idSchema,
  filename: z.string(),
  size_bytes: z.number(),
  edit_session_id: idSchema.optional(),
  comment_draft_id: idSchema.optional(),
});
function checked<T>(result: { data: T; error: unknown }): T {
  if (result.error) throw result.error;
  return result.data;
}
// Mark before removing: the Storage insert policy locks this same metadata row.
// Keep the record if object removal fails, making cleanup safely retryable.
export async function removeAttachment(
  admin: SupabaseClient,
  id: string,
  draftOwner?: string,
) {
  let removal = admin
    .from("attachments")
    .update({ status: "deleting" })
    .eq("id", id)
    .is("held_by_session", null);
  // Recheck atomically after waiting for a concurrent comment publication. A
  // failed/ambiguous send must never delete files that were actually published.
  if (draftOwner)
    removal = removal
      .eq("uploaded_by", draftOwner)
      .not("comment_draft_id", "is", null);
  const item = checked(await removal.select("object_path").maybeSingle());
  if (!item) return;
  checked(await admin.storage.from(BUCKET).remove([item.object_path]));
  checked(await admin.from("attachments").delete().eq("id", id));
}
export async function cleanupAttachments(
  admin: SupabaseClient,
  uploader?: string,
  cardId?: string,
) {
  let query = admin
    .from("attachments")
    .select("id")
    .or("status.neq.ready,comment_draft_id.not.is.null")
    .is("held_by_session", null)
    .lt("expires_at", new Date().toISOString())
    .limit(100);
  if (uploader) query = query.eq("uploaded_by", uploader);
  if (cardId) query = query.eq("card_id", cardId);
  const rows = checked(await query);
  for (const row of rows || []) await removeAttachment(admin, row.id);
  if (!uploader) {
    let deleted = admin
      .from("cards")
      .select("id")
      .not("deleted_at", "is", null)
      .limit(100);
    if (cardId) deleted = deleted.eq("id", cardId);
    for (const row of checked(await deleted) || [])
      checked(
        await admin.rpc("card_edit_cleanup", { p_card: row.id, p_purge: true }),
      );
  }
  return rows?.length || 0;
}
export async function cleanupCardEdits(
  req: Request,
  res: Response,
  next: NextFunction,
) {
  try {
    const id = idSchema.parse(req.params.id);
    const access = checked(
      await (res.locals.user as SupabaseClient).rpc("card_edit_cleanup", {
        p_card: id,
      }),
    );
    if (!access) {
      res.status(204).end();
      return;
    }
    await cleanupAttachments(res.locals.admin, undefined, id);
    res.status(204).end();
  } catch (error) {
    next(error);
  }
}
async function visibleCard(user: SupabaseClient, id: string) {
  const { data, error } = await user
    .from("cards")
    .select("id,archived_at")
    .eq("id", id)
    .maybeSingle();
  if (error) throw error;
  if (!data) throw new AttachmentError(404, "Die Karte wurde nicht gefunden.");
  if (data.archived_at)
    throw new AttachmentError(409, "Archivierte Karten können nicht geändert werden.");
}
export const attachmentRouter = Router();
// Always authorize through live table RLS before touching server-only Storage.
// Direct authenticated Storage downloads may reuse CDN authorization decisions.
attachmentRouter.get("/:id/download", async (req, res, next) => {
  const controller = new AbortController();
  const abort = () => controller.abort();
  res.once("close", abort);
  try {
    const id = idSchema.parse(req.params.id);
    const item = checked(
      await (res.locals.user as SupabaseClient)
        .from("attachments")
        .select("object_path,filename,mime_type,size_bytes")
        .eq("id", id)
        .eq("status", "ready")
        .maybeSingle(),
    );
    if (!item) throw new AttachmentError(404, "Anhang nicht gefunden.");
    const range = req.headers.range;
    if (range && !/^bytes=(?:\d+-\d*|-\d+)$/.test(range))
      throw new AttachmentError(416, "Ungültiger Dateibereich.");
    const url = process.env.SUPABASE_URL;
    const secret = process.env.SUPABASE_SECRET_KEY;
    if (!url || !secret) throw new Error("NOT_CONFIGURED");
    const objectPath = item.object_path
      .split("/")
      .map(encodeURIComponent)
      .join("/");
    const upstream = await fetch(
      `${url}/storage/v1/object/authenticated/${BUCKET}/${objectPath}?cacheNonce=${randomUUID()}`,
      {
        headers: {
          apikey: secret,
          Authorization: `Bearer ${secret}`,
          ...(range ? { Range: range } : {}),
        },
        cache: "no-store",
        signal: controller.signal,
      },
    );
    if (!upstream.ok || !upstream.body) {
      await upstream.body?.cancel();
      throw new AttachmentError(
        upstream.status === 416 ? 416 : 502,
        "Datei momentan nicht verfügbar.",
      );
    }
    res.status(upstream.status);
    res.attachment(item.filename);
    res.setHeader("Content-Type", item.mime_type);
    res.setHeader("Cache-Control", "private, no-store, max-age=0");
    res.setHeader("CDN-Cache-Control", "no-store");
    res.setHeader("Vercel-CDN-Cache-Control", "no-store");
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.vary("Authorization");
    for (const header of ["content-length", "content-range", "accept-ranges"]) {
      const value = upstream.headers.get(header);
      if (value) res.setHeader(header, value);
    }
    // Backpressure keeps 500 MB downloads out of process memory; disconnects
    // cancel the upstream stream rather than continuing a billable transfer.
    await pipeline(
      Readable.fromWeb(upstream.body as Parameters<typeof Readable.fromWeb>[0]),
      res,
    );
  } catch (error) {
    if (res.headersSent) res.destroy();
    else if (!controller.signal.aborted) next(error);
  } finally {
    res.off("close", abort);
  }
});
attachmentRouter.post("/", async (req, res, next) => {
  try {
    const input = inputSchema.parse(req.body);
    let mime: string;
    try {
      mime = validateFile(input.filename, input.size_bytes);
    } catch (e) {
      throw new AttachmentError(400, (e as Error).message);
    }
    const admin: SupabaseClient = res.locals.admin;
    await visibleCard(res.locals.user, input.card_id);
    if (input.edit_session_id) {
      const session = await (res.locals.user as SupabaseClient).rpc(
        "card_edit_session",
        {
          p_session: input.edit_session_id,
          p_operation: "touch",
          p_card: input.card_id,
        },
      );
      if (session.error)
        throw new AttachmentError(
          409,
          "Diese Kartenansicht ist nicht mehr verfügbar. Bitte erneut öffnen.",
        );
    }
    await cleanupAttachments(admin, undefined, input.card_id);
    const result = await admin
      .from("attachments")
      .insert({
        ...input,
        mime_type: mime,
        uploaded_by: res.locals.actor,
      })
      .select("*")
      .single();
    if (result.error?.code === "23514")
      throw new AttachmentError(
        409,
        "Höchstens 20 Kartenanhänge bzw. 10 Dateien pro Nachricht möglich.",
      );
    res.status(201).json(checked(result));
  } catch (e) {
    next(e);
  }
});
attachmentRouter.post("/:id/complete", async (req, res, next) => {
  try {
    const id = idSchema.parse(req.params.id);
    const admin: SupabaseClient = res.locals.admin;
    const item = checked(
      await admin
        .from("attachments")
        .select("*")
        .eq("id", id)
        .eq("uploaded_by", res.locals.actor)
        .maybeSingle(),
    );
    if (!item) throw new AttachmentError(404, "Anhang nicht gefunden.");
    await visibleCard(res.locals.user, item.card_id);
    if (item.status === "ready") {
      res.json(item);
      return;
    }
    if (item.status !== "pending" || Date.parse(item.expires_at) <= Date.now())
      throw new AttachmentError(
        409,
        "Der Upload ist abgelaufen. Bitte erneut hochladen.",
      );
    const object = await admin.storage.from(BUCKET).info(item.object_path);
    if (object.error)
      throw new AttachmentError(
        409,
        "Der Upload ist noch nicht vollständig angekommen.",
      );
    if (
      object.data.size !== item.size_bytes ||
      object.data.contentType?.split(";")[0] !== item.mime_type
    ) {
      await removeAttachment(admin, id);
      throw new AttachmentError(
        400,
        "Dateigröße oder Dateityp stimmen nicht mit dem Upload überein.",
      );
    }
    // Storage's authoritative size/type were checked above. Opaque downloads
    // have no format to parse. Previewable formats remain capped at 20 MB.
    let validContent = item.mime_type === "application/octet-stream";
    if (!validContent && item.size_bytes <= MAX_PREVIEW_SIZE) {
      const blob = checked(
        await admin.storage.from(BUCKET).download(item.object_path),
      );
      validContent =
        !!blob &&
        blob.size === item.size_bytes &&
        validFileBytes(
          new Uint8Array(await blob.arrayBuffer()),
          item.mime_type,
        );
    }
    if (!validContent) {
      await removeAttachment(admin, id);
      throw new AttachmentError(
        400,
        "Der Dateiinhalt passt nicht zum Dateityp. Bitte eine gültige Datei verwenden.",
      );
    }
    if (item.edit_session_id && !item.comment_draft_id) {
      const finalized = await admin.rpc("complete_card_edit_upload", {
        p_session: item.edit_session_id,
        p_attachment: id,
        p_actor: res.locals.actor,
      });
      if (finalized.error)
        throw new AttachmentError(
          409,
          "Die Kartenansicht ist abgelaufen. Bitte Karte erneut öffnen und hochladen.",
        );
      res.json(
        checked(
          await admin.from("attachments").select("*").eq("id", id).single(),
        ),
      );
      return;
    }
    const ready = checked(
      await admin
        .from("attachments")
        .update({ status: "ready" })
        .eq("id", id)
        .eq("status", "pending")
        .gt("expires_at", new Date().toISOString())
        .select("*")
        .maybeSingle(),
    );
    if (!ready)
      throw new AttachmentError(
        409,
        "Der Upload wurde inzwischen abgebrochen.",
      );
    res.json(ready);
  } catch (e) {
    next(e);
  }
});
attachmentRouter.delete("/:id", async (req, res, next) => {
  try {
    const id = idSchema.parse(req.params.id);
    const item = checked(
      await (res.locals.user as SupabaseClient)
        .from("attachments")
        .select("card_id")
        .eq("id", id)
        .maybeSingle(),
    );
    if (item) {
      await visibleCard(res.locals.user, item.card_id);
      await removeAttachment(
        res.locals.admin,
        id,
        req.query.draft === "1" ? res.locals.actor : undefined,
      );
    }
    res.status(204).end();
  } catch (e) {
    next(e);
  }
});
attachmentRouter.use(
  (e: unknown, _req: Request, res: Response, next: NextFunction) => {
    if (e instanceof z.ZodError) {
      res
        .status(400)
        .json({ error: "Bitte eine gültige Datei und Karte auswählen." });
      return;
    }
    next(e);
  },
);
export async function deleteCardWithAttachments(
  req: Request,
  res: Response,
  next: NextFunction,
) {
  try {
    const id = idSchema.parse(req.params.id);
    await visibleCard(res.locals.user, id);
    const rows = checked(
      await (res.locals.admin as SupabaseClient)
        .from("attachments")
        .select("id")
        .eq("card_id", id),
    );
    for (const row of rows || [])
      await removeAttachment(res.locals.admin, row.id);
    const result = await (res.locals.user as SupabaseClient)
      .from("cards")
      .delete()
      .eq("id", id)
      .select("id")
      .single();
    if (result.error?.code === "23503")
      throw new AttachmentError(
        409,
        "Es läuft noch ein Upload. Bitte kurz warten und erneut löschen.",
      );
    checked(result);
    res.status(204).end();
  } catch (e) {
    next(e);
  }
}
