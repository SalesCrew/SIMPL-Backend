import type { NextFunction, Request, Response } from "express";
import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";

const moveSchema = z.object({
  column_id: z.string().uuid(),
  before_id: z.string().uuid().nullable().optional(),
}).strict();

export async function moveCard(req: Request, res: Response, next: NextFunction) {
  const id = z.string().uuid().safeParse(req.params.id);
  const input = moveSchema.safeParse(req.body);
  if (!id.success || !input.success) {
    res.status(400).json({ error: "Bitte eine gültige Karte und Zielspalte wählen." });
    return;
  }
  try {
    // Deliberately do not pass request/response close events or an AbortSignal to
    // Supabase. Once accepted, the server finishes this transaction even if the
    // browser navigates away or its connection drops. Always use the caller's JWT,
    // never the service client: password gating, NDA isolation and RLS still apply.
    const user: SupabaseClient = res.locals.user;
    const result = await user.rpc("move_card_with_receipt", {
      p_card: id.data,
      p_column: input.data.column_id,
      p_before: input.data.before_id || null,
    });
    if (result.error) {
      const denied = result.error.code === "42501";
      if (!res.destroyed) res.status(denied ? 403 : 409).json({
        error: denied ? "Kein Zugriff auf diese Karte oder Zielspalte."
          : "Karte konnte nicht verschoben werden. Bitte das Board aktualisieren.",
      });
      return;
    }
    if (!res.destroyed) res.json({ cards: result.data });
  } catch (error) {
    // A disconnected response cannot be written to, but the database work above
    // has still been awaited; there is no unobserved fire-and-forget promise.
    if (!res.destroyed) next(error);
    else console.error("Disconnected card move failed", { code: "MOVE_FAILED" });
  }
}
