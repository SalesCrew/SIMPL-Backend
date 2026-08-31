-- Trello permitted cards created directly in a status list, sometimes with
-- multiple project labels. Preserve that uncertainty instead of inventing an
-- original project. Live cards must still belong to a real project.
alter table public.cards alter column project_id drop not null;
alter table public.cards add constraint cards_live_project_required
  check (project_id is not null or archived_at is not null);

create or replace function private.check_card_workspace() returns trigger
language plpgsql set search_path='' as $$
declare target_workspace uuid;
begin
  select workspace_id into target_workspace from public.columns where id=new.column_id;
  if tg_op='INSERT' and new.workspace_id is null then new.workspace_id:=target_workspace; end if;
  if tg_op='UPDATE' and new.workspace_id is distinct from old.workspace_id then
    raise exception 'Der Workspace einer Karte kann nicht geändert werden.';
  end if;
  if new.workspace_id is distinct from target_workspace
    or not ((new.archived_at is not null and new.project_id is null)
      or exists(select 1 from public.columns where id=new.project_id and workspace_id=new.workspace_id and kind='project')) then
    raise exception 'Karte und Projekt müssen zum gleichen Workspace gehören.';
  end if;
  return new;
end;
$$;

-- Archive history is read-only including its children, not only the card row.
create policy active_card_comments_insert on public.comments as restrictive for insert to authenticated
  with check (exists(select 1 from public.cards c where c.id=card_id and c.archived_at is null));
create policy active_card_comments_update on public.comments as restrictive for update to authenticated
  using (exists(select 1 from public.cards c where c.id=card_id and c.archived_at is null))
  with check (exists(select 1 from public.cards c where c.id=card_id and c.archived_at is null));
create policy active_card_comments_delete on public.comments as restrictive for delete to authenticated
  using (exists(select 1 from public.cards c where c.id=card_id and c.archived_at is null));
create policy active_card_attachments_insert on public.attachments as restrictive for insert to authenticated
  with check (exists(select 1 from public.cards c where c.id=card_id and c.archived_at is null));
create policy active_card_attachments_update on public.attachments as restrictive for update to authenticated
  using (exists(select 1 from public.cards c where c.id=card_id and c.archived_at is null))
  with check (exists(select 1 from public.cards c where c.id=card_id and c.archived_at is null));
create policy active_card_attachments_delete on public.attachments as restrictive for delete to authenticated
  using (exists(select 1 from public.cards c where c.id=card_id and c.archived_at is null));
