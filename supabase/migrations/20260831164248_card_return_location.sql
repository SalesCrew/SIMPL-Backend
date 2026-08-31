-- Remember the last real project slot; work/done are temporary status buckets.
alter table public.cards
  add column return_column_id uuid,
  add column return_before_id uuid,
  add column return_after_id uuid,
  add column return_index integer check (return_index >= 0),
  add constraint card_return_workspace foreign key (workspace_id,return_column_id)
    references public.columns(workspace_id,id) on delete restrict;
create index cards_return_workspace on public.cards(workspace_id,return_column_id)
  where return_column_id is not null;

-- Neighbor IDs are deliberately soft references: deleted/moved neighbors fall
-- back to the other neighbor, then the remembered index. No dangling card FK.
create function private.remember_card_return_location() returns trigger
language plpgsql security invoker set search_path = '' as $$
declare source_kind text; target_kind text;
begin
  if tg_op = 'INSERT' then
    new.return_column_id := null;
    new.return_before_id := null;
    new.return_after_id := null;
    new.return_index := null;
    return new;
  end if;
  -- Never trust return metadata supplied by a browser/console update.
  new.return_column_id := old.return_column_id;
  new.return_before_id := old.return_before_id;
  new.return_after_id := old.return_after_id;
  new.return_index := old.return_index;
  if new.column_id is not distinct from old.column_id then return new; end if;
  select kind into source_kind from public.columns where id = old.column_id;
  select kind into target_kind from public.columns where id = new.column_id;
  if target_kind = 'project' then
    new.return_column_id := null;
    new.return_before_id := null;
    new.return_after_id := null;
    new.return_index := null;
  elsif source_kind = 'project' then
    new.return_column_id := old.column_id;
    select id into new.return_before_id from public.cards
      where column_id = old.column_id and deleted_at is null
      and (position,id) > (old.position,old.id) order by position,id limit 1;
    select id into new.return_after_id from public.cards
      where column_id = old.column_id and deleted_at is null
      and (position,id) < (old.position,old.id) order by position desc,id desc limit 1;
    select count(*) into new.return_index from public.cards
      where column_id = old.column_id and deleted_at is null
      and (position,id) < (old.position,old.id);
  end if;
  return new;
end;
$$;
revoke all on function private.remember_card_return_location() from public,anon,authenticated;
create trigger zz_remember_card_return_location before insert or update on public.cards
for each row execute function private.remember_card_return_location();

create or replace function public.set_card_completed(p_card uuid,p_completed boolean)
returns void language plpgsql security invoker set search_path = '' as $$
declare c public.cards; done_column uuid; target_column uuid; before_card uuid; previous_card public.cards;
begin
  if auth.uid() is null or not private.is_member() then raise exception 'Authentication required'; end if;
  if p_completed is null then raise exception 'Completion status required'; end if;
  perform pg_advisory_xact_lock(hashtext('trello-plus-card-order'));
  select * into c from public.cards where id = p_card for update;
  if not found then raise exception 'Card not found'; end if;
  select id into done_column from public.columns where kind = 'done' and workspace_id = c.workspace_id;
  if done_column is null then raise exception 'Die feste Fertig-Spalte fehlt.'; end if;
  if (p_completed and c.column_id = done_column) or (not p_completed and c.column_id <> done_column) then return; end if;
  if p_completed then
    perform public.move_card(p_card,done_column,null);
    return;
  end if;
  select id into target_column from public.columns
    where id = c.return_column_id and workspace_id = c.workspace_id and kind = 'project';
  target_column := coalesce(target_column,c.project_id);
  select id into before_card from public.cards
    where id = c.return_before_id and column_id = target_column and deleted_at is null;
  if before_card is null then
    select * into previous_card from public.cards
      where id = c.return_after_id and column_id = target_column and deleted_at is null;
    if found then
      select id into before_card from public.cards where column_id = target_column and deleted_at is null
        and (position,id) > (previous_card.position,previous_card.id) order by position,id limit 1;
    elsif c.return_index is not null then
      select id into before_card from public.cards where column_id = target_column and deleted_at is null
        order by position,id offset c.return_index limit 1;
    end if;
  end if;
  perform public.move_card(p_card,target_column,before_card);
end;
$$;
revoke all on function public.set_card_completed(uuid,boolean) from public,anon;
grant execute on function public.set_card_completed(uuid,boolean) to authenticated;

-- Undo restores origin metadata only from the existing private, locked session
-- snapshot. Caller-controlled flags or payloads cannot enable this override.
create or replace function private.restore_edit_timestamps() returns trigger
language plpgsql security definer set search_path = '' as $$
declare saved jsonb;
begin
  select initial_card into saved from private.card_edit_sessions
  where card_id = new.id and owner_id = auth.uid() and undoing;
  if found then
    new.completed_at := (saved->>'completed_at')::timestamptz;
    new.reviewed_at := (saved->>'reviewed_at')::timestamptz;
    new.reviewed_by := (saved->>'reviewed_by')::uuid;
    new.return_column_id := (saved->>'return_column_id')::uuid;
    new.return_before_id := (saved->>'return_before_id')::uuid;
    new.return_after_id := (saved->>'return_after_id')::uuid;
    new.return_index := (saved->>'return_index')::integer;
  end if;
  return new;
end;
$$;
revoke all on function private.restore_edit_timestamps() from public,anon,authenticated;
