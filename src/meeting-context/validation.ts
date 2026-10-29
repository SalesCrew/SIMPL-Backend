import { createHash } from "node:crypto";
import { Ajv } from "ajv";
import schema from "./contract-v1.schema.json" with { type: "json" };
export const MEETING_VERSION = "salescrew.meeting.v1";
export const MAX_MEETING_BYTES = 1_048_576;
const validateSchema = new Ajv({ allErrors: false, strict: false }).compile(schema);
export function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return "[" + value.map(canonicalJson).join(",") + "]";
  if (value && typeof value === "object") return "{" + Object.keys(value).sort().map(key => JSON.stringify(key) + ":" + canonicalJson((value as Record<string, unknown>)[key])).join(",") + "}";
  return JSON.stringify(value) ?? "null";
}
export function meetingHash(input: Record<string, unknown>) {
  const value = Object.fromEntries(Object.entries(input).filter(([key]) => !["content_hash", "exported_at", "revision", "base_revision"].includes(key)));
  return createHash("sha256").update(canonicalJson(value), "utf8").digest("hex");
}
export const CONTRACT_HASH = createHash("sha256").update(canonicalJson(schema), "utf8").digest("hex");
export function allowedMeetingContent(value: unknown) {
  let text = canonicalJson(value).normalize("NFKC").replace(/[\u200B\u200C\u200D\uFEFF]/g, "").toLowerCase();
  for (let i = 0; i < 3; i++) { if (text.includes("%00")) return false; text = text.replace(/%([a-f0-9]{2})/g, (_all, code: string) => String.fromCharCode(parseInt(code, 16))).replace(/&#(x[0-9a-f]+|[0-9]+);/g, (_all, code: string) => (parseInt(code.startsWith("x") ? code.slice(1) : code, code.startsWith("x") ? 16 : 10)<=1114111?String.fromCodePoint(parseInt(code.startsWith("x") ? code.slice(1) : code, code.startsWith("x") ? 16 : 10)||0):"")).replace(/&(?:hyphen|dash);/g, "-").replace(/&sol;/g, "/").replace(/&period;/g, ".").replace(/<[^>]*>/g, "").toLowerCase(); }
  return !/(s[\s_./-]*academy|(^|[^a-z])sak([^a-z]|$))/.test(text);
}
export function validateMeetingExport(value: unknown): { ok: true } | { ok: false; code: string } {
  if (Buffer.byteLength(canonicalJson(value), "utf8") > MAX_MEETING_BYTES) return { ok: false, code: "MEETING_PAYLOAD_TOO_LARGE" };
  if (!validateSchema(value)) return { ok: false, code: "MEETING_SCHEMA_INVALID" };
  const sections = (value as { sections: { primary_label_id: string | null; label_ids: string[] }[] }).sections;
  if (sections.some(section => section.label_ids.some(id => ["780f22ad-988c-41a1-8463-b84fe82969d8", "130989d7-dcfb-4c55-b673-3a10a14f95dd"].includes(id)) && section.primary_label_id !== "b8f71d57-9822-5aba-a977-d3dc7ff95655")) return { ok: false, code: "MEETING_LABEL_SCOPE_INVALID" };
  if (!allowedMeetingContent(value)) return { ok: false, code: "MEETING_CONTENT_EXCLUDED" };
  if (meetingHash(value as Record<string, unknown>) !== (value as Record<string, unknown>).content_hash) return { ok: false, code: "MEETING_HASH_MISMATCH" };
  return { ok: true };
}
