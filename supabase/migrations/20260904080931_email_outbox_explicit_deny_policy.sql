-- The outbox is intentionally server-only. An explicit deny policy documents
-- that boundary and keeps it visible to Supabase's security advisor in addition
-- to the table-level privilege revocations in the preceding migration.
create policy email_outbox_no_client_access on public.email_outbox
for all to authenticated using (false) with check (false);
