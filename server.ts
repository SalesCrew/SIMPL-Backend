import "dotenv/config";
import express, {
  type Request,
  type Response,
  type NextFunction,
} from "express";
import cors from "cors";
import {
  contentSecurityPolicy,
  crossOriginOpenerPolicy,
  crossOriginResourcePolicy,
  originAgentCluster,
  referrerPolicy,
  strictTransportSecurity,
  xContentTypeOptions,
  xDnsPrefetchControl,
  xDownloadOptions,
  xFrameOptions,
  xPermittedCrossDomainPolicies,
  xXssProtection,
} from "helmet";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import {
  attachmentRouter,
  AttachmentError,
  deleteCardWithAttachments,
  cleanupCardEdits,
} from "./src/attachments.js";
import {
  canEditProfile,
  createProfileSchema,
  profileSchema,
} from "./src/validation.js";

export const app = express();
app.disable("x-powered-by");
// Named exports work consistently in both Node ESM and Vercel's Express builder.
app.use(
  contentSecurityPolicy(),
  crossOriginOpenerPolicy(),
  crossOriginResourcePolicy(),
  originAgentCluster(),
  referrerPolicy(),
  strictTransportSecurity(),
  xContentTypeOptions(),
  xDnsPrefetchControl(),
  xDownloadOptions(),
  xFrameOptions(),
  xPermittedCrossDomainPolicies(),
  xXssProtection(),
);
const allowedOrigins = (process.env.FRONTEND_ORIGINS || "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);
app.use(
  cors({
    origin(origin, callback) {
      if (!origin || allowedOrigins.includes(origin)) callback(null, true);
      else callback(new Error("ORIGIN_DENIED"));
    },
    methods: ["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
    allowedHeaders: ["Authorization", "Content-Type"],
  }),
);
app.use(express.json({ limit: "16kb" }));
app.use((_req, res, next) => {
  res.setHeader("Cache-Control", "no-store");
  next();
});
app.get("/api/health", (_req, res) => {
  res.json({
    ok: true,
    service: "trello-plus-backend",
    configured: Boolean(
      process.env.SUPABASE_URL && process.env.SUPABASE_SECRET_KEY,
    ),
  });
});

function clients(token: string) {
  const {
    SUPABASE_URL: url,
    SUPABASE_PUBLISHABLE_KEY: key,
    SUPABASE_SECRET_KEY: secret,
  } = process.env;
  if (!url || !key || !secret) throw new Error("NOT_CONFIGURED");
  return {
    user: createClient(url, key, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${token}` } },
    }),
    admin: createClient(url, secret, {
      auth: { persistSession: false, autoRefreshToken: false },
    }),
  };
}
async function memberOnly(req: Request, res: Response, next: NextFunction) {
  const match = req.headers.authorization?.match(/^Bearer (.+)$/);
  if (!match) {
    res.status(401).json({ error: "Bitte anmelden." });
    return;
  }
  try {
    const { user, admin } = clients(match[1]);
    const { data, error } = await user.auth.getUser(match[1]);
    if (error || !data.user) {
      res
        .status(401)
        .json({ error: "Sitzung abgelaufen. Bitte erneut anmelden." });
      return;
    }
    const profile = await user
      .from("profiles")
      .select("id,role,active")
      .eq("id", data.user.id)
      .single();
    if (profile.error || !profile.data?.active) {
      res.status(403).json({ error: "Dein Zugang ist nicht freigeschaltet." });
      return;
    }
    res.locals.actor = data.user.id;
    res.locals.admin = admin;
    res.locals.user = user;
    res.locals.role = profile.data.role;
    next();
  } catch (error) {
    next(error);
  }
}
app.use("/api/users", memberOnly, (_req, res, next) => {
  if (res.locals.role !== "admin") {
    res
      .status(403)
      .json({ error: "Nur Administratoren dürfen Zugänge verwalten." });
    return;
  }
  next();
});
app.use("/api/attachments", memberOnly, attachmentRouter);
app.delete("/api/cards/:id", memberOnly, deleteCardWithAttachments);
app.post("/api/cards/:id/cleanup", memberOnly, cleanupCardEdits);
async function validProject(
  admin: SupabaseClient,
  id: string | null,
  workspaceId?: string,
) {
  if (workspaceId) {
    const workspace = await admin
      .from("workspaces")
      .select("id")
      .eq("id", workspaceId)
      .single();
    if (workspace.error || !workspace.data) return false;
  }
  if (!id) return true;
  const { data, error } = await admin
    .from("columns")
    .select("id,workspace_id")
    .eq("id", id)
    .eq("kind", "project")
    .single();
  return (
    !error &&
    Boolean(data) &&
    (!workspaceId || data.workspace_id === workspaceId)
  );
}
app.post("/api/users", async (req, res, next) => {
  try {
    const input = createProfileSchema.parse(req.body);
    const admin: SupabaseClient = res.locals.admin;
    if (
      !(await validProject(
        admin,
        input.default_column_id,
        input.default_workspace_id,
      ))
    ) {
      res.status(400).json({
        error: "Bitte Workspace und passendes Standardprojekt wählen.",
      });
      return;
    }
    const { data, error } = await admin.auth.admin.createUser({
      email: input.email,
      password: input.password,
      email_confirm: true,
    });
    if (error || !data.user) {
      res.status(400).json({
        error:
          error?.code === "email_exists"
            ? "Diese E-Mail ist bereits registriert."
            : "Zugang konnte nicht erstellt werden. E-Mail und Passwort prüfen.",
      });
      return;
    }
    const { password: _password, ...profile } = input;
    const result = await admin
      .from("profiles")
      .insert({ ...profile, id: data.user.id });
    if (result.error) {
      // Compensate only the newly created Auth account if profile provisioning fails.
      const rollback = await admin.auth.admin.deleteUser(data.user.id);
      if (rollback.error)
        console.error("Account provisioning rollback failed", {
          userId: data.user.id,
          code: rollback.error.code,
        });
      throw result.error;
    }
    res.status(201).json({ id: data.user.id });
  } catch (error) {
    next(error);
  }
});
app.patch("/api/users/:id", async (req, res, next) => {
  try {
    const id = z.string().uuid().parse(req.params.id);
    const input = profileSchema.parse(req.body);
    const admin: SupabaseClient = res.locals.admin;
    if (!canEditProfile(res.locals.actor, id, input)) {
      res.status(400).json({
        error: "Du kannst deinen eigenen Admin-Zugang nicht entfernen.",
      });
      return;
    }
    if (
      !(await validProject(
        admin,
        input.default_column_id,
        input.default_workspace_id,
      ))
    ) {
      res.status(400).json({
        error: "Bitte Workspace und passendes Standardprojekt wählen.",
      });
      return;
    }
    const old = await admin.from("profiles").select("*").eq("id", id).single();
    if (old.error || !old.data) {
      res.status(404).json({ error: "Zugang nicht gefunden." });
      return;
    }
    if (input.email !== old.data.email) {
      res
        .status(400)
        .json({ error: "Die E-Mail-Adresse kann hier nicht geändert werden." });
      return;
    }
    const { password, ...profile } = input;
    // RLS consults active immediately, so even previously issued tokens lose data access.
    const updated = await admin
      .from("profiles")
      .update(profile)
      .eq("id", id)
      .select("id")
      .single();
    if (updated.error) throw updated.error;
    if (password) {
      const changed = await admin.auth.admin.updateUserById(id, { password });
      if (changed.error) {
        res.status(502).json({
          error:
            "Profil gespeichert, Passwortänderung fehlgeschlagen. Bitte das Passwort erneut setzen.",
        });
        return;
      }
    }
    res.json({ id });
  } catch (error) {
    next(error);
  }
});
app.use((_req, res) => {
  res.status(404).json({ error: "Nicht gefunden." });
});
app.use((error: unknown, _req: Request, res: Response, _next: NextFunction) => {
  if (error instanceof AttachmentError) {
    res.status(error.status).json({ error: error.message });
    return;
  }
  if (error instanceof z.ZodError) {
    res.status(400).json({
      error:
        "Bitte alle Felder prüfen. Passwörter benötigen mindestens 12 Zeichen.",
    });
    return;
  }
  const message = error instanceof Error ? error.message : "";
  if (message === "ORIGIN_DENIED") {
    res.status(403).json({ error: "Diese Website ist nicht freigeschaltet." });
    return;
  }
  if (message === "NOT_CONFIGURED") {
    res
      .status(503)
      .json({ error: "Der Admin-Backend-Zugang ist noch nicht eingerichtet." });
    return;
  }
  if (
    error instanceof SyntaxError ||
    (error as { type?: string })?.type === "entity.too.large"
  ) {
    res.status(400).json({ error: "Ungültige Anfrage." });
    return;
  }
  console.error("Request failed", {
    code: (error as { code?: string })?.code || "unknown",
  });
  res.status(500).json({
    error:
      "Die Änderung konnte nicht gespeichert werden. Bitte erneut versuchen.",
  });
});
export default app;
