-- Preserve all existing IDs, cards and project assignments.
-- Stop safely if a legacy workspace needs a deliberate status-column repair.
do $$
begin
  if (select count(*) from public.columns where kind = 'work') <> 1 or
     (select count(*) from public.columns where kind = 'done') <> 1 then
    raise exception 'Expected exactly one In Arbeit and one Fertig column before locking status buckets';
  end if;
end;
$$;
create unique index one_work_column on public.columns (kind) where kind = 'work';
alter table public.columns add constraint fixed_status_names check (
  (kind = 'work' and name = 'In Arbeit') or
  (kind = 'done' and name = 'Fertig') or
  (kind = 'project' and lower(trim(name)) not in ('in arbeit','fertig'))
);

create or replace function private.validate_column() returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    if old.kind <> 'project' then raise exception 'In Arbeit und Fertig sind feste Spalten und können nicht gelöscht werden.'; end if;
    return old;
  end if;
  if tg_op = 'UPDATE' then
    if old.kind <> 'project' then raise exception 'In Arbeit und Fertig sind feste Spalten und können nicht bearbeitet werden.'; end if;
  end if;
  if new.kind <> 'project' then raise exception 'Es können nur Projekt-Spalten erstellt oder bearbeitet werden.'; end if;
  return new;
end;
$$;
revoke all on function private.validate_column() from public,anon,authenticated;

drop trigger validate_column on public.columns;
create trigger validate_column before insert or update or delete on public.columns for each row execute function private.validate_column();

create function public.set_card_completed(p_card uuid,p_completed boolean) returns void language plpgsql security invoker set search_path = '' as $$
declare current_column uuid; original_project uuid; done_column uuid; target_column uuid;
begin
  if auth.uid() is null or not private.is_member() then raise exception 'Authentication required'; end if;
  if p_completed is null then raise exception 'Completion status required'; end if;
  -- Use the move RPC's lock order; concurrent completions are idempotent.
  perform pg_advisory_xact_lock(hashtext('trello-plus-card-order'));
  select column_id,project_id into current_column,original_project from public.cards where id = p_card for update;
  if not found then raise exception 'Card not found'; end if;
  select id into done_column from public.columns where kind = 'done';
  if done_column is null then raise exception 'Die feste Fertig-Spalte fehlt.'; end if;
  if not p_completed and current_column <> done_column then return; end if;
  target_column := case when p_completed then done_column else original_project end;
  if current_column = target_column then return; end if;
  perform public.move_card(p_card,target_column,null);
end;
$$;
revoke all on function public.set_card_completed(uuid,boolean) from public,anon;
grant execute on function public.set_card_completed(uuid,boolean) to authenticated;

create function private.project_card_creation() returns trigger language plpgsql set search_path = '' as $$
begin
  if not exists(select 1 from public.columns where id = new.column_id and kind = 'project') then
    raise exception 'Neue Karten werden in einem Projekt erstellt. Danach können sie verschoben oder abgehakt werden.';
  end if;
  return new;
end;
$$;
revoke all on function private.project_card_creation() from public,anon,authenticated;
create trigger project_card_creation before insert on public.cards for each row execute function private.project_card_creation();
