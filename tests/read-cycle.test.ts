import { describe, expect, it } from "vitest";
import { readCycle } from "../src/read-cycle.js";
const owner = "owner", snapshot = new Date("2026-10-30T12:00:00Z");
const card = { created_at: "2026-10-01T10:00:00Z", reviewed_at: "2026-10-26T10:00:00Z", reviewed_by: owner, completed_at: "2026-10-27T13:00:00Z" };
describe("native acknowledgement to finish calendar duration", () => {
  it("uses acknowledgement, not creation, as the start and counts overnight time", () => {
    expect(readCycle(card, owner, snapshot)).toEqual({ read_to_finish_hours: 27, read_to_finish_status: "valid" });
    expect(readCycle({ ...card, completed_at: card.reviewed_at }, owner, snapshot).read_to_finish_hours).toBe(0);
  });
  it("measures elapsed hours across Vienna daylight saving, not wall-clock subtraction", () => {
    expect(readCycle({ ...card, reviewed_at: "2026-10-25T00:30:00Z", completed_at: "2026-10-25T02:30:00Z" }, owner, snapshot).read_to_finish_hours).toBe(2);
  });
  it("rejects imported review stamps even when the migrated card was finished later", () => {
    expect(readCycle({ ...card, created_at: "2026-06-01T00:00:00Z", reviewed_at: "2026-08-24T10:00:00Z" }, owner, snapshot).read_to_finish_status).toBe("imported-review");
  });
  it("accepts a migrated card only after a real native re-acknowledgement", () => {
    expect(readCycle({ ...card, created_at: "2026-06-01T00:00:00Z" }, owner, snapshot).read_to_finish_hours).toBe(27);
  });
  it.each([
    [{ reviewed_at: null }, "missing-review"], [{ reviewed_by: "someone" }, "other-reviewer"],
    [{ completed_at: null }, "no-finish"], [{ completed_at: "invalid" }, "invalid-stamp"],
    [{ reviewed_at: "invalid" }, "invalid-stamp"], [{ created_at: "invalid" }, "invalid-stamp"],
    [{ reviewed_at: "2026-09-25T10:00:00Z" }, "review-before-creation"],
    [{ reviewed_at: "2026-10-28T10:00:00Z" }, "review-after-finish"],
    [{ completed_at: "2026-11-01T10:00:00Z" }, "future-finish"],
  ])("leaves unsupported stamps empty: %s", (patch, status) => {
    expect(readCycle({ ...card, ...patch }, owner, snapshot)).toEqual({ read_to_finish_hours: null, read_to_finish_status: status });
  });
});
