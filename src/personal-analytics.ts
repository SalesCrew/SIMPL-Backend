import { Router, type NextFunction, type Request, type Response } from "express";
import type { SupabaseClient } from "@supabase/supabase-js";
import { ANALYSIS_LABEL_IDS } from "./meeting-context/labels.js";
import { meetingContextRouter } from "./meeting-context/routes.js";

// Verified against the single active public.profiles identity on 2026-10-29.
// Role, display name, caller-supplied email and user_metadata confer no access.
export const PERSONAL_ANALYTICS_OWNER = "e68b62cd-06b3-4300-8a16-dc04e20ed75d";
const DEVELOPMENT_WORKSPACE = "2bb0db3c-9ec4-4066-8f58-0a7712fb6325";
const PAGE_SIZE = 500;
const MAX_CARDS = 20_000;
const CARD_FIELDS = "id,title,created_at,completed_at,archived_at,deleted_at,project_id,label_ids";
type SourceCard = { id: string; title: string; created_at: string; completed_at: string | null; archived_at: string | null; deleted_at: string | null; project_id: string | null; label_ids: string[] | null };
const parts = new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Vienna", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
function localStamp(value: string | null) {
  if (!value || !Number.isFinite(Date.parse(value))) return null;
  const p = Object.fromEntries(parts.formatToParts(new Date(value)).map(part => [part.type, part.value]));
  return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute}`;
}
export function personalAnalyticsPayload(cards: SourceCard[], projects: { id: string; name: string; color?: string }[], labels: { id: string; name: string; color?: string }[], snapshot: Date, workspaceName: string) {
  const projectMap = new Map(projects.map(p => [p.id, p.name])), labelMap = new Map(labels.map(l => [l.id, l.name]));
  const retained = cards.filter(c => !c.deleted_at), snapshotAt = snapshot.toISOString(), snapshotLocal = localStamp(snapshotAt)!;
  const tasks = retained.map(card => {
    const effectiveCompletion = card.completed_at || card.archived_at;
    const created = Date.parse(card.created_at), end = effectiveCompletion ? Date.parse(effectiveCompletion) : NaN;
    return {
      id: card.id, title: card.title, project: projectMap.get(card.project_id || "") || "Ohne Projekt",
      created_at: card.created_at, completed_at: effectiveCompletion, original_completed_at: card.completed_at,
      archived_at: card.archived_at, deleted_at: null, label_ids: card.label_ids || [], labels: (card.label_ids || []).map(id => labelMap.get(id)).filter((name): name is string => Boolean(name)),
      created_date: localStamp(card.created_at)?.slice(0, 10) || null,
      created_local: localStamp(card.created_at), finished_local: localStamp(effectiveCompletion),
      archive_date: localStamp(card.archived_at)?.slice(0, 10) || null,
      completion_source: card.completed_at ? "completed" : card.archived_at ? "archive-fallback" : null,
      duration_hours: Number.isFinite(created) && Number.isFinite(end) && end >= created ? (end - created) / 3_600_000 : null,
    };
  });
  const validDates = tasks.flatMap(t => [t.created_at, t.completed_at]).filter((value): value is string => Boolean(value) && Number.isFinite(Date.parse(value!)) && Date.parse(value!) <= snapshot.getTime()).map(t => localStamp(t)!.slice(0, 10)).sort();
  const firstDate = validDates[0] || snapshotLocal.slice(0, 10);
  const meta = { workspace: workspaceName, snapshot_at: snapshotAt, snapshot_vienna: snapshotLocal, first_date: firstDate, last_date: snapshotLocal.slice(0, 10), total_cards: tasks.length, closed_cards: tasks.filter(t => t.completed_at).length, open_cards: tasks.filter(t => !t.completed_at).length, archive_fallback_cards: tasks.filter(t => t.completion_source === "archive-fallback").length };
  return { label_catalog: labels.map(label => ({ ...label, primary: ANALYSIS_LABEL_IDS.has(label.id) })), project_catalog: projects, meta, flow_meta: meta, flow_tasks: tasks, tasks: tasks.filter(t => t.completed_at), coverage: { start_date: firstDate, source: "earliest_available_date", confirmed_complete: false, note: "Gesamte verfügbare Historie einschließlich Trello-Importen. Frühere Ereignisse können unvollständig sein." } };
}

export const personalAnalyticsRouter = Router();
// The existing memberOnly middleware has already verified the Auth token,
// fresh active profile and initial-password gate before reaching this router.
personalAnalyticsRouter.use((_req: Request, res: Response, next: NextFunction) => {
  res.vary("Authorization");
  res.setHeader("Cache-Control", "private, no-store, max-age=0");
  if (res.locals.actor !== PERSONAL_ANALYTICS_OWNER) {
    res.status(404).json({ error: "Nicht gefunden." });
    return;
  }
  next();
});
personalAnalyticsRouter.use("/meetings", meetingContextRouter);
personalAnalyticsRouter.get("/access", (req, res) => {
  if (Object.keys(req.query).length) { res.status(400).json({ error: "Ungültige Anfrage." }); return; }
  res.json({ allowed: true });
});
personalAnalyticsRouter.get("/", async (req, res, next) => {
  if (Object.keys(req.query).length) { res.status(400).json({ error: "Ungültige Anfrage." }); return; }
  try {
    const snapshot = new Date(), user = res.locals.user as SupabaseClient;
    // Business reads deliberately use the caller's JWT and existing RLS, never
    // the admin client. The workspace cannot be selected through request input.
    const workspace = await user.from("workspaces").select("id,name").eq("id", DEVELOPMENT_WORKSPACE).maybeSingle();
    if (workspace.error) throw workspace.error;
    if (!workspace.data) { res.status(404).json({ error: "Nicht gefunden." }); return; }
    const [projects, labels] = await Promise.all([
      user.from("columns").select("id,name,color").eq("workspace_id", DEVELOPMENT_WORKSPACE).eq("kind", "project"),
      user.from("labels").select("id,name,color").eq("workspace_id", DEVELOPMENT_WORKSPACE),
    ]);
    if (projects.error || labels.error) throw projects.error || labels.error;
    const cards: SourceCard[] = []; let after: string | null = null;
    for (;;) {
      let query = user.from("cards").select(CARD_FIELDS).eq("workspace_id", DEVELOPMENT_WORKSPACE).is("deleted_at", null).order("id", { ascending: true }).limit(PAGE_SIZE);
      if (after) query = query.gt("id", after);
      const page = await query;
      if (page.error) throw page.error;
      const rows = (page.data || []) as SourceCard[];
      if (cards.length + rows.length > MAX_CARDS) { res.status(409).json({ error: "Der Datenbestand ist für einen vollständigen Abruf zu groß. Bitte die Auswertung technisch erweitern; es wurden keine Teilmengen ausgewertet." }); return; }
      cards.push(...rows);
      if (rows.length < PAGE_SIZE) break;
      const cursor = rows.at(-1)!.id;
      if (after && cursor <= after) throw new Error("INVALID_ANALYTICS_CURSOR");
      after = cursor;
    }
    res.json(personalAnalyticsPayload(cards, projects.data || [], labels.data || [], snapshot, workspace.data.name));
  } catch (error) { next(error); }
});
