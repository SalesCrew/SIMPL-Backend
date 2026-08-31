-- Explicit deny policy documents the private snapshot table's closed access model.
create policy no_direct_edit_history_access on private.card_edit_sessions
for all to authenticated using (false) with check (false);
create index cards_deleted_cleanup_idx on public.cards(deleted_at) where deleted_at is not null;

-- Remove only the empty workspace created by this feature's real Storage test.
-- User/card/file fixture cleanup has already succeeded. Abort on any unexpected data.
do $$
declare target uuid;
begin
  select id into target from public.workspaces where name = 'Card edit storage QA' for update;
  if target is null then return; end if;
  if (select count(*) from public.workspaces where name = 'Card edit storage QA') <> 1
    or exists(select 1 from public.cards where workspace_id = target)
    or exists(select 1 from public.profiles where default_workspace_id = target)
    or exists(select 1 from public.labels where workspace_id = target)
  then raise exception 'Refusing cleanup: storage QA workspace is not empty or unique'; end if;
  delete from public.workspace_blocks where workspace_a = target or workspace_b = target;
  alter table public.columns disable trigger validate_column;
  delete from public.columns where workspace_id = target;
  alter table public.columns enable trigger validate_column;
  delete from public.workspaces where id = target;
end;
$$;
