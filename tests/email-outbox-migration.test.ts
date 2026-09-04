import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync(new URL(
  "../supabase/migrations/20260904080814_workspace_email_outbox.sql",
  import.meta.url,
), "utf8");
const denyPolicy = readFileSync(new URL(
  "../supabase/migrations/20260904080931_email_outbox_explicit_deny_policy.sql",
  import.meta.url,
), "utf8");

describe("workspace email outbox migration", () => {
  it("queues exactly the four requested activity events without backfilling history", () => {
    for (const event of [
      "comment.created",
      "card.created",
      "card.reviewed",
      "card.completed",
    ]) expect(migration).toContain(`'${event}'`);
    expect(migration).not.toMatch(/insert into public\.email_outbox[\s\S]+select[\s\S]+from public\.notifications/i);
  });

  it("rechecks live access, excludes the actor and keeps the queue server-only", () => {
    expect(migration).toContain("private.user_can_access_workspace(recipient.id,o.workspace_id)");
    expect(migration).toContain("o.recipient_id <> o.actor_id");
    expect(migration).toContain("alter table public.email_outbox enable row level security");
    expect(migration).toContain("revoke all on public.email_outbox from public,anon,authenticated,service_role");
    expect(migration).toContain("grant execute on function public.claim_email_outbox(integer) to service_role");
    expect(denyPolicy).toContain("for all to authenticated using (false) with check (false)");
  });

  it("uses leases, bounded retries and terminal delivery states", () => {
    expect(migration).toContain("for update of o skip locked");
    expect(migration).toContain("attempt_count between 0 and 8");
    expect(migration).toContain("o.lease_token = p_lease");
    expect(migration).toContain("num_nonnulls(sent_at,discarded_at) <= 1");
    expect(migration).toContain("interval '30 days'");
    expect(migration).toContain("create index email_outbox_recipient");
    expect(migration).toContain("create index email_outbox_workspace");
  });
});
