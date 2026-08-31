-- Preserve source archive/checklist state without turning archived cards into
-- active work or changing their original text. Existing card RLS also protects
-- these columns; the import ledger is never exposed to authenticated clients.
alter table public.cards
  add column archived_at timestamptz,
  add column due_at timestamptz,
  add column checklists jsonb not null default '[]'::jsonb;
create index cards_workspace_archive on public.cards(workspace_id,archived_at);
-- Archive history is a read-only snapshot in this version of the app. Import
-- maintenance remains server-only; clients cannot forge an archive timestamp.
create policy active_cards_update on public.cards as restrictive for update to authenticated
  using (archived_at is null) with check (archived_at is null);
create policy active_cards_insert on public.cards as restrictive for insert to authenticated
  with check (archived_at is null);
create policy active_cards_delete on public.cards as restrictive for delete to authenticated
  using (archived_at is null);

create function private.valid_card_checklists(value jsonb) returns boolean
language plpgsql immutable strict security invoker set search_path = '' as $$
declare checklist jsonb; item jsonb;
begin
  if jsonb_typeof(value) is distinct from 'array' or octet_length(value::text)>100000 then return false; end if;
  if jsonb_array_length(value)>20 then return false; end if;
  if (select count(*)<>count(distinct x->>'id') from jsonb_array_elements(value) x) then return false; end if;
  for checklist in select * from jsonb_array_elements(value) loop
    if jsonb_typeof(checklist) is distinct from 'object'
      or jsonb_typeof(checklist->'id') is distinct from 'string'
      or length(checklist->>'id') not between 1 and 100
      or jsonb_typeof(checklist->'name') is distinct from 'string'
      or length(trim(checklist->>'name')) not between 1 and 500
      or jsonb_typeof(checklist->'items') is distinct from 'array' then return false; end if;
    if exists(select 1 from jsonb_object_keys(checklist) k where k not in ('id','name','items'))
      or jsonb_array_length(checklist->'items')>200 then return false; end if;
    if (select count(*)<>count(distinct x->>'id') from jsonb_array_elements(checklist->'items') x) then return false; end if;
    for item in select * from jsonb_array_elements(checklist->'items') loop
      if jsonb_typeof(item) is distinct from 'object'
        or jsonb_typeof(item->'id') is distinct from 'string'
        or length(item->>'id') not between 1 and 100
        or jsonb_typeof(item->'name') is distinct from 'string'
        or length(trim(item->>'name')) not between 1 and 2000
        or jsonb_typeof(item->'completed') is distinct from 'boolean' then return false; end if;
      if exists(select 1 from jsonb_object_keys(item) k where k not in ('id','name','completed')) then return false; end if;
    end loop;
  end loop;
  return true;
end;
$$;
revoke all on function private.valid_card_checklists(jsonb) from public,anon;
grant execute on function private.valid_card_checklists(jsonb) to authenticated,service_role;
alter table public.cards add constraint cards_valid_checklists check(private.valid_card_checklists(checklists));

create table private.trello_migration_rows (
  source_id text primary key,
  source_kind text not null,
  target_id uuid,
  source_payload jsonb not null,
  imported_at timestamptz not null default clock_timestamp()
);
alter table private.trello_migration_rows enable row level security;
revoke all on private.trello_migration_rows from public,anon,authenticated;
grant all on private.trello_migration_rows to service_role;

-- Include checklist saves in the existing conflict-aware edit session and undo.
do $migration$
declare original text; updated text;
begin
  original := pg_get_functiondef('private.card_edit_operation(uuid,text,uuid,jsonb,uuid)'::regprocedure);
  updated := replace(original,
    'k not in (''title'',''description'',''assignee_id'',''label_ids'')',
    'k not in (''title'',''description'',''assignee_id'',''label_ids'',''checklists'')');
  if updated=original then raise exception 'Unexpected card patch allowlist'; end if;
  original := updated;
  updated := replace(original,
    'label_ids = case when p_action->''patch'' ? ''label_ids''',
    'checklists = case when p_action->''patch'' ? ''checklists'' then p_action->''patch''->''checklists'' else checklists end,
        label_ids = case when p_action->''patch'' ? ''label_ids''');
  if updated=original then raise exception 'Unexpected card patch assignment'; end if;
  original := updated;
  updated := replace(original,'assignee_id = saved.assignee_id,label_ids = saved.label_ids,',
    'checklists = coalesce(saved.checklists,''[]''::jsonb),assignee_id = saved.assignee_id,label_ids = saved.label_ids,');
  if updated=original then raise exception 'Unexpected card undo assignment'; end if;
  original := updated;
  updated := replace(original,
    'array[''title'',''description'',''assignee_id'',''label_ids'',''column_id''',
    'array[''title'',''description'',''assignee_id'',''label_ids'',''checklists'',''column_id''');
  if updated=original then raise exception 'Unexpected card edit event fields'; end if;
  execute updated;
end;
$migration$;

-- Archived cards must not affect live ordering or the exact return location.
do $migration$
declare original text; updated text; routine text;
begin
  original := pg_get_functiondef('public.move_card(uuid,uuid,uuid)'::regprocedure);
  updated := replace(original,'where column_id = p_column','where archived_at is null and deleted_at is null and column_id = p_column');
  updated := replace(updated,'where id = p_card','where archived_at is null and deleted_at is null and id = p_card');
  updated := replace(updated,'where id = p_before','where archived_at is null and deleted_at is null and id = p_before');
  if updated=original then raise exception 'Unexpected card ordering function'; end if;
  execute updated;
  foreach routine in array array['public.set_card_completed(uuid,boolean)','private.remember_card_return_location()'] loop
    original := pg_get_functiondef(routine::regprocedure);
    updated := replace(original,'and deleted_at is null','and deleted_at is null and archived_at is null');
    if updated=original then raise exception 'Unexpected return-location function %',routine; end if;
    execute updated;
  end loop;
end;
$migration$;
