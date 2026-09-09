import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync(new URL(
  "../supabase/migrations/20260909134008_show_workspace_admins_in_member_lists.sql",
  import.meta.url,
), "utf8");

describe("workspace member visibility migration", () => {
  it("shows global admins alongside members assigned to an accessible workspace", () => {
    expect(migration).toContain("alter policy member_profiles");
    expect(migration).toContain("role = 'admin'");
    expect(migration).toContain("default_workspace_id = any");
    expect(migration).toContain("private.accessible_workspace_ids()");
    expect(migration).toContain("private.is_member()");
  });
});
