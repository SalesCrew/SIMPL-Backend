import express, { Router } from "express";
import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import { CONTRACT_HASH, MEETING_VERSION, validateMeetingExport } from "./validation.js";
const OWNER = "e68b62cd-06b3-4300-8a16-dc04e20ed75d", WORKSPACE = "2bb0db3c-9ec4-4066-8f58-0a7712fb6325";
const uuid = z.string().uuid();
const listQuery = z.object({ after: uuid.optional() }).strict();
const scopeQuery = z.object({ label_id: uuid.optional(), section_id: uuid.optional() }).strict();
const listFields = "section_id,meeting_id,project_id,primary_label_id,label_ids,note_ref,presentation,comparison_review_required";
const detailFields = "section_id,meeting_id,project_id,primary_label_id,label_ids,note_ref,presentation,comparison,changes,actions,followups,sources,comparison_review_required";
export const meetingContextRouter = Router();
// Parent router enforces the verified active owner before these handlers.
meetingContextRouter.get("/contract", async (_req, res, next) => {
  try {
    const result = await (res.locals.user as SupabaseClient).rpc("personal_meeting_contract_v1");
    if (result.error) throw result.error;
    if (!result.data?.ready || result.data.schema_hash !== CONTRACT_HASH) { res.status(503).json({ ready: false, code: "MEETING_CONTRACT_MISMATCH" }); return; }
    res.json({ ...result.data, schema_version: MEETING_VERSION });
  } catch (error) { next(error); }
});
meetingContextRouter.get("/", async (req, res, next) => {
  const parsed = listQuery.safeParse(req.query); if (!parsed.success) { res.status(400).json({ error: "Ungültige Anfrage." }); return; }
  try {
    const client = res.locals.user as SupabaseClient;
    let query = client.from("personal_meetings").select("id,kind,title,meeting_date,starts_at,ends_at,date_precision,date_status,revision,synced_at").eq("owner_id", OWNER).eq("workspace_id", WORKSPACE).order("id").limit(100);
    if (parsed.data.after) query = query.gt("id", parsed.data.after);
    const [meetings, projects, labels] = await Promise.all([query, client.from("columns").select("id,name,color").eq("workspace_id", WORKSPACE).eq("kind", "project"), client.from("labels").select("id,name,color").eq("workspace_id", WORKSPACE)]);
    if (meetings.error || projects.error || labels.error) throw meetings.error || projects.error || labels.error;
    const ids = (meetings.data || []).map(row => row.id);
    const sections = ids.length ? await client.from("personal_meeting_sections").select(listFields).eq("owner_id", OWNER).eq("workspace_id", WORKSPACE).in("meeting_id", ids).order("section_id").limit(800) : { data: [], error: null };
    if (sections.error) throw sections.error;
    // Only three compact headlines/title/highlight leave this endpoint; no summaries or transcripts.
    const compact = (sections.data || []).map(row => ({ ...row, presentation: { title: row.presentation.title, headlines: row.presentation.headlines, highlight: row.presentation.highlight } }));
    res.json({ schema_version: MEETING_VERSION, meetings: (meetings.data || []).map(row => ({ ...row, sections: compact.filter(section => section.meeting_id === row.id) })), projects: projects.data || [], labels: labels.data || [], next: ids.length === 100 ? ids.at(-1) : null });
  } catch (error) { next(error); }
});
meetingContextRouter.get("/:id", async (req, res, next) => {
  const id = uuid.safeParse(req.params.id), parsed = scopeQuery.safeParse(req.query); if (!id.success || !parsed.success) { res.status(400).json({ error: "Ungültige Anfrage." }); return; }
  try {
    const client = res.locals.user as SupabaseClient;
    const meeting = await client.from("personal_meetings").select("id,kind,title,meeting_date,starts_at,ends_at,date_precision,date_status,timezone,revision,synced_at,metadata").eq("id", id.data).eq("owner_id", OWNER).eq("workspace_id", WORKSPACE).maybeSingle();
    if (meeting.error) throw meeting.error;
    let query = client.from("personal_meeting_sections").select(detailFields).eq("meeting_id", id.data).eq("owner_id", OWNER).eq("workspace_id", WORKSPACE).order("section_id");
    if (parsed.data.label_id) query = query.eq("primary_label_id", parsed.data.label_id);
    if (parsed.data.section_id) query = query.eq("section_id", parsed.data.section_id);
    const sections = await query;
    if (sections.error) throw sections.error;
    if (!meeting.data || !sections.data?.length) { res.status(404).json({ error: "Nicht gefunden." }); return; }
    // Root metadata contains only shared frame fields, never another project's section text.
    const { participants, duration, occurred, note_created_on, note_updated_at } = meeting.data.metadata;
    res.json({ ...meeting.data, title: parsed.data.label_id ? sections.data[0].presentation.title : meeting.data.title, metadata: { participants, duration, occurred, note_created_on, note_updated_at }, sections: sections.data });
  } catch (error) { next(error); }
});
meetingContextRouter.get("/:id/protocol/:section", async (req, res, next) => {
  const id = uuid.safeParse(req.params.id), section = uuid.safeParse(req.params.section), parsed = z.object({ label_id: uuid.optional() }).strict().safeParse(req.query);
  if (!id.success || !section.success || !parsed.success) { res.status(400).json({ error: "Ungültige Anfrage." }); return; }
  try {
    const client = res.locals.user as SupabaseClient;
    let query = client.from("personal_meeting_sections").select("section_id,meeting_id,project_id,primary_label_id,note_ref,markdown,sources").eq("meeting_id", id.data).eq("section_id", section.data).eq("owner_id", OWNER).eq("workspace_id", WORKSPACE);
    if (parsed.data.label_id) query = query.eq("primary_label_id", parsed.data.label_id);
    const result = await query.maybeSingle();
    if (result.error) throw result.error;
    if (!result.data) { res.status(404).json({ error: "Nicht gefunden." }); return; }
    res.json(result.data);
  } catch (error) { next(error); }
});
const syncJson = express.json({ limit: "1mb" });
meetingContextRouter.post("/sync", (req, res, next) => syncJson(req, res, error => {
  if (error) { res.status(error.type === "entity.too.large" ? 413 : 422).json({ error: "Meetingexport nicht übernommen.", code: error.type === "entity.too.large" ? "MEETING_PAYLOAD_TOO_LARGE" : "MEETING_SCHEMA_INVALID" }); return; }
  next();
}), async (req, res, next) => {
  if (Object.keys(req.query).length) { res.status(400).json({ error: "Ungültige Anfrage." }); return; }
  const validated = validateMeetingExport(req.body);
  if (!validated.ok) { res.status(validated.code === "MEETING_PAYLOAD_TOO_LARGE" ? 413 : 422).json({ error: "Meetingexport nicht übernommen.", code: validated.code }); return; }
  try {
    const result = await (res.locals.user as SupabaseClient).rpc("sync_personal_meeting_v1", { p_export: req.body, p_dry_run: false });
    if (result.error) {
      const code = /^MEETING_[A-Z_]+$/.test(result.error.message) ? result.error.message : "MEETING_SYNC_FAILED";
      res.status(code.endsWith("CONFLICT") ? 409 : result.error.code === "42501" ? 403 : 422).json({ error: "Meetingexport nicht übernommen.", code }); return;
    }
    res.json(result.data);
  } catch (error) { next(error); }
});
