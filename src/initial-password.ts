import type { Request, Response, NextFunction } from "express";
import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";

export const initialPasswordSchema = z.object({
  password: z.string().min(12).max(128),
  repeatPassword: z.string().min(12).max(128),
}).strict().refine(input => input.password === input.repeatPassword, {
  message: "Die Passwörter stimmen nicht überein.", path: ["repeatPassword"],
});

// Registered behind identity/active-profile validation, but before the workspace
// gate. Auth, not client metadata, validates the password change.
export async function changeInitialPassword(req: Request, res: Response, next: NextFunction) {
  const admin: SupabaseClient = res.locals.admin;
  const actor: string = res.locals.actor;
  const token: string = res.locals.token;
  let operation: string | null = null;
  try {
    const parsed = initialPasswordSchema.safeParse(req.body);
    if (!parsed.success) {
      res.status(400).json({ error: req.body?.password !== req.body?.repeatPassword
        ? "Die Passwörter stimmen nicht überein."
        : "Dein neues Passwort braucht 12 bis 128 Zeichen." });
      return;
    }
    const claim = await admin.rpc("begin_password_change", { p_user: actor });
    if (claim.error) throw claim.error;
    operation = claim.data;
    if (!operation) {
      res.status(409).json({ error: "Die Passwortänderung läuft bereits oder ist schon abgeschlossen. Bitte erneut anmelden." });
      return;
    }
    const changed = await fetch(`${process.env.SUPABASE_URL}/auth/v1/user`, {
      method: "PUT",
      headers: {
        apikey: process.env.SUPABASE_PUBLISHABLE_KEY!,
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ password: parsed.data.password }),
      signal: AbortSignal.timeout(30000),
    });
    if (!changed.ok) {
      const detail = await changed.json().catch(() => ({}));
      res.status(changed.status === 429 ? 429 : 400).json({
        error: detail.code === "same_password" || detail.error_code === "same_password"
          ? "Bitte wähle ein anderes Passwort als dein Startpasswort."
          : "Das Passwort konnte nicht geändert werden. Bitte wähle ein starkes neues Passwort und versuche es erneut.",
      });
      return;
    }
    const revoked = await admin.auth.admin.signOut(token, "global");
    if (revoked.error) throw revoked.error;
    const completed = await admin.rpc("complete_password_change", { p_user: actor, p_operation: operation });
    if (completed.error) throw completed.error;
    if (!completed.data) {
      res.status(409).json({ error: "Der Zugang wurde währenddessen zurückgesetzt. Bitte erneut anmelden." });
      return;
    }
    operation = null;
    // A new session, created after the database stamp, is required by RLS. Old
    // temporary-password JWTs remain blocked even before their natural expiry.
    res.json({ changed: true, sign_in_required: true });
  } catch (error) {
    next(error);
  } finally {
    if (operation) {
      const cancelled = await admin.rpc("cancel_password_change", { p_user: actor, p_operation: operation });
      if (cancelled.error) console.error("Password change lease cleanup failed", { code: cancelled.error.code });
    }
  }
}
