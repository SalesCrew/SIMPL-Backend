-- project_id is the card's current real project. In Arbeit and Fertig are
-- temporary status buckets and keep that project; moving to another project
-- changes it atomically with column_id so filters can never lag behind.
create or replace function private.validate_card() returns trigger
language plpgsql set search_path = '' as $$
declare target_kind text;
begin
  if tg_op = 'INSERT' then
    new.created_by := auth.uid();
    new.created_at := now();
    new.reviewed_at := null;
    new.reviewed_by := null;
    perform pg_advisory_xact_lock(hashtext('trello-plus-card-order'));
    new.position := coalesce((select max(position) from public.cards where column_id = new.column_id),0) + 1024;
  else
    if new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at then
      raise exception 'Creator cannot be changed';
    end if;
    if new.reviewed_at is distinct from old.reviewed_at or new.reviewed_by is distinct from old.reviewed_by then
      if auth.uid() is null or not private.is_member() then raise exception 'Authentication required' using errcode = '42501'; end if;
      new.reviewed_by := case when new.reviewed_at is null then null else auth.uid() end;
      new.reviewed_at := case when new.reviewed_at is null then null else now() end;
    end if;
  end if;

  select kind into target_kind from public.columns where id = new.column_id;
  if target_kind is null then raise exception 'Invalid target column'; end if;
  if target_kind = 'project' and new.project_id is distinct from new.column_id then
    raise exception 'Card project must match its project column';
  end if;
  if new.project_id is null then
    if new.archived_at is null then raise exception 'Active card requires a project'; end if;
  elsif not exists(select 1 from public.columns where id = new.project_id and kind = 'project') then
    raise exception 'Invalid card project';
  end if;
  if tg_op = 'UPDATE' and new.project_id is distinct from old.project_id
    and (target_kind <> 'project' or new.project_id is distinct from new.column_id) then
    raise exception 'Project can only change with a move to that project';
  end if;
  if exists(select 1 from unnest(new.label_ids) x where x is null or not exists(select 1 from public.labels where id = x)) then raise exception 'Invalid label'; end if;
  if new.assignee_id is not null and (tg_op = 'INSERT' or new.assignee_id is distinct from old.assignee_id) and not exists(select 1 from public.profiles where id = new.assignee_id and active) then raise exception 'Invalid assignee'; end if;

  if new.archived_at is not null then
    new.completed_at := coalesce(new.completed_at,new.archived_at);
    if tg_op = 'UPDATE' then new.updated_at := old.updated_at; end if;
  else
    new.completed_at := case when target_kind = 'done' then coalesce(case when tg_op = 'UPDATE' then old.completed_at end,now()) else null end;
    new.updated_at := now();
  end if;
  return new;
end;
$$;

create or replace function public.move_card(p_card uuid,p_column uuid,p_before uuid default null)
returns void language plpgsql security invoker set search_path = '' as $$
declare next_pos double precision; previous_pos double precision; target_kind text;
begin
  if auth.uid() is null or not private.is_member() then raise exception 'Authentication required'; end if;
  if p_before = p_card then return; end if;
  perform pg_advisory_xact_lock(hashtext('trello-plus-card-order'));
  if not exists(select 1 from public.cards where archived_at is null and deleted_at is null and id = p_card) then raise exception 'Card not found'; end if;
  select kind into target_kind from public.columns where id = p_column;
  if target_kind is null then raise exception 'Column not found'; end if;
  with positions as (
    select id,row_number() over(order by position,id) * 1024 as pos
    from public.cards where archived_at is null and deleted_at is null and column_id = p_column and id <> p_card
  )
  update public.cards c set position = p.pos from positions p where c.id = p.id;
  if p_before is not null then
    select position into next_pos from public.cards where archived_at is null and deleted_at is null and id = p_before and column_id = p_column;
    if next_pos is null then raise exception 'Target card no longer exists in column'; end if;
    select coalesce(max(position),next_pos-2048) into previous_pos from public.cards where archived_at is null and deleted_at is null and column_id = p_column and id <> p_card and position < next_pos;
    next_pos := (previous_pos + next_pos) / 2;
  else
    select coalesce(max(position),0)+1024 into next_pos from public.cards where archived_at is null and deleted_at is null and column_id = p_column and id <> p_card;
  end if;
  update public.cards set
    column_id = p_column,
    project_id = case when target_kind = 'project' then p_column else project_id end,
    position = next_pos
  where archived_at is null and deleted_at is null and id = p_card;
end;
$$;

-- Repair the one class of legacy mismatch generically, then make every archive
-- an explicitly completed read-only record without inventing a later time.
update public.cards c set project_id = c.column_id
from public.columns target
where target.id = c.column_id and target.kind = 'project'
  and c.archived_at is null and c.deleted_at is null
  and c.project_id is distinct from c.column_id;

update public.cards set completed_at = archived_at
where archived_at is not null and completed_at is null and deleted_at is null;

do $$
begin
  if exists(
    select 1 from public.cards c join public.columns target on target.id=c.column_id
    where c.archived_at is null and c.deleted_at is null and target.kind='project'
      and c.project_id is distinct from c.column_id
  ) then raise exception 'Active project mismatch remains'; end if;
  if exists(select 1 from public.cards where archived_at is not null and completed_at is null and deleted_at is null) then
    raise exception 'Archived incomplete card remains';
  end if;
end;
$$;
