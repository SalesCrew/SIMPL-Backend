// Verified from Development's private Trello import ledger on 2026-10-30.
// Imported historical review stamps are not native acknowledgements. This
// boundary applies only to this metric, never to all-time completion counts.
export const NATIVE_REVIEW_FROM = "2026-08-31T19:39:15.870Z";
export const NATIVE_REVIEW_FIRST_FULL_DAY = "2026-09-01";
export type ReadCycleStatus = "valid" | "missing-review" | "imported-review" | "other-reviewer" | "no-finish" | "invalid-stamp" | "review-before-creation" | "review-after-finish" | "future-finish";
type Stamps = { created_at: string; completed_at: string | null; reviewed_at?: string | null; reviewed_by?: string | null };

export function readCycle(card: Stamps, owner: string, snapshot: Date): { read_to_finish_hours: number | null; read_to_finish_status: ReadCycleStatus } {
  const result = (status: ReadCycleStatus, hours: number | null = null) => ({ read_to_finish_hours: hours, read_to_finish_status: status });
  if (!card.reviewed_at) return result("missing-review");
  const read = Date.parse(card.reviewed_at), created = Date.parse(card.created_at);
  if (!Number.isFinite(read) || !Number.isFinite(created)) return result("invalid-stamp");
  if (read < Date.parse(NATIVE_REVIEW_FROM)) return result("imported-review");
  if (card.reviewed_by !== owner) return result("other-reviewer");
  if (read < created) return result("review-before-creation");
  // Archiving alone is not a Fertig press and cannot provide this metric's end.
  if (!card.completed_at) return result("no-finish");
  const done = Date.parse(card.completed_at);
  if (!Number.isFinite(done)) return result("invalid-stamp");
  if (done > snapshot.getTime()) return result("future-finish");
  if (read > done) return result("review-after-finish");
  return result("valid", (done - read) / 3_600_000);
}
