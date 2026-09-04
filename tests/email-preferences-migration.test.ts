import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync(new URL(
  "../supabase/migrations/20260904103241_user_email_preferences.sql",
  import.meta.url,
), "utf8");
const indexMigration = readFileSync(new URL(
  "../supabase/migrations/20260904103332_email_preference_foreign_key_indexes.sql",
  import.meta.url,
), "utf8");

describe("user email preferences migration", () => {
  it("creates owner-scoped event, workspace and project controls", () => {
    expect(migration).toContain("create table public.email_notification_settings");
    expect(migration).toContain("create table public.email_notification_workspace_preferences");
    expect(migration).toContain("create table public.email_notification_project_preferences");
    expect(migration).toContain("user_id = (select auth.uid())");
    expect(migration).toContain("private.has_password_access()");
    expect(migration).toContain("alter table public.email_notification_settings enable row level security");
    expect(migration).toContain("grant select,insert,update,delete");
  });

  it("enforces preferences before enqueue and again before delivery", () => {
    expect(migration).toContain("private.email_notification_allowed(");
    expect(migration).toContain("recipient_preference_disabled");
    expect(migration).toContain("o.recipient_id,o.workspace_id,o.project_id,o.event_type");
    expect(migration).toContain("add column project_id uuid references public.columns(id)");
  });

  it("indexes reverse workspace and project preference lookups", () => {
    expect(indexMigration).toContain("(workspace_id,user_id)");
    expect(indexMigration).toContain("(project_id,user_id)");
  });
});
