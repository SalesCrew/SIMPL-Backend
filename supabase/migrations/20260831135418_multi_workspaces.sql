-- Add multiple shared workspaces without changing existing IDs or content.
create table public.workspaces (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 60),
  color public.workspace_color not null default 'green',
  created_at timestamptz not null default now()
);
create unique index workspace_unique_name on public.workspaces(lower(trim(name)));
alter table public.workspaces enable row level security;
revoke all on public.workspaces from anon,authenticated;
grant select,insert,update on public.workspaces to authenticated;
grant all on public.workspaces to service_role;
create policy member_workspaces on public.workspaces for select to authenticated using ((select private.is_member()));
create policy admin_workspaces_insert on public.workspaces for insert to authenticated with check ((select private.is_admin()));
create policy admin_workspaces_update on public.workspaces for update to authenticated using ((select private.is_admin())) with check ((select private.is_admin()));

-- This is the only existing workspace. No generated ID is hardcoded.
insert into public.workspaces(name,color) values ('SalesCrew','green');
alter table public.columns add column workspace_id uuid references public.workspaces(id) on delete restrict;
alter table public.cards add column workspace_id uuid references public.workspaces(id) on delete restrict;
alter table public.profiles add column default_workspace_id uuid references public.workspaces(id) on delete restrict;

-- DDL locks keep the backfill atomic; suppress only triggers that would rewrite
-- timestamps or reject the fixed columns, then immediately restore them.
alter table public.columns disable trigger validate_column;
alter table public.cards disable trigger validate_card;
update public.columns set workspace_id = (select id from public.workspaces);
update public.cards set workspace_id = (select id from public.workspaces);
update public.profiles set default_workspace_id = (select id from public.workspaces);
alter table public.columns enable trigger validate_column;
alter table public.cards enable trigger validate_card;
alter table public.columns alter column workspace_id set not null;
alter table public.cards alter column workspace_id set not null;
alter table public.profiles alter column default_workspace_id set not null;

drop index public.one_work_column;
drop index public.one_done_column;
create unique index one_work_column on public.columns(workspace_id) where kind = 'work';
create unique index one_done_column on public.columns(workspace_id) where kind = 'done';
alter table public.columns add constraint columns_workspace_id_unique unique(workspace_id,id);
alter table public.cards add constraint card_column_workspace foreign key(workspace_id,column_id) references public.columns(workspace_id,id) on delete restrict;
alter table public.cards add constraint card_project_workspace foreign key(workspace_id,project_id) references public.columns(workspace_id,id) on delete restrict;
alter table public.profiles add constraint profile_project_workspace foreign key(default_workspace_id,default_column_id) references public.columns(workspace_id,id) on delete restrict;
create index cards_workspace_column on public.cards(workspace_id,column_id,position);
create index cards_workspace_project on public.cards(workspace_id,project_id);
create index profiles_workspace_project on public.profiles(default_workspace_id,default_column_id);

create or replace function private.validate_column() returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    if old.kind <> 'project' then raise exception 'In Arbeit und Fertig sind feste Spalten und können nicht gelöscht werden.'; end if;
    return old;
  end if;
  if tg_op = 'UPDATE' then
    if old.kind <> 'project' then raise exception 'In Arbeit und Fertig sind feste Spalten und können nicht bearbeitet werden.'; end if;
    if new.kind <> old.kind or new.workspace_id is distinct from old.workspace_id then raise exception 'Art und Workspace einer Spalte können nicht geändert werden.'; end if;
  else
    -- Compatibility for pre-workspace clients creating ordinary projects.
    if new.workspace_id is null then select id into new.workspace_id from public.workspaces order by created_at,id limit 1; end if;
    -- Only the nested workspace-seeding trigger can create the initial buckets.
    -- A direct API write cannot control trigger depth; uniqueness is enforced too.
    if new.kind <> 'project' and (pg_trigger_depth() <> 2 or exists(select 1 from public.columns where workspace_id = new.workspace_id and kind = new.kind)) then
      raise exception 'Es können nur Projekt-Spalten erstellt werden.';
    end if;
  end if;
  return new;
end;
$$;

create function private.seed_workspace() returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  insert into public.columns(workspace_id,name,color,kind,position) values
    (new.id,'Allgemein','blue','project',0),
    (new.id,'In Arbeit','orange','work',1),
    (new.id,'Fertig','green','done',2);
  return new;
end;
$$;
revoke all on function private.seed_workspace() from public,anon,authenticated;
create trigger seed_workspace after insert on public.workspaces for each row execute function private.seed_workspace();

create function private.validate_workspace() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.id is distinct from old.id or new.created_at is distinct from old.created_at then raise exception 'Workspace identity cannot be changed'; end if;
  return new;
end;
$$;
revoke all on function private.validate_workspace() from public,anon,authenticated;
create trigger validate_workspace before update on public.workspaces for each row execute function private.validate_workspace();

create function private.check_card_workspace() returns trigger language plpgsql set search_path = '' as $$
declare target_workspace uuid;
begin
  select workspace_id into target_workspace from public.columns where id = new.column_id;
  if tg_op = 'INSERT' and new.workspace_id is null then new.workspace_id := target_workspace; end if;
  if tg_op = 'UPDATE' and new.workspace_id is distinct from old.workspace_id then raise exception 'Der Workspace einer Karte kann nicht geändert werden.'; end if;
  if new.workspace_id is distinct from target_workspace or not exists(select 1 from public.columns where id = new.project_id and workspace_id = new.workspace_id and kind = 'project') then
    raise exception 'Karte und Projekt müssen zum gleichen Workspace gehören.';
  end if;
  return new;
end;
$$;
revoke all on function private.check_card_workspace() from public,anon,authenticated;
create trigger check_card_workspace before insert or update on public.cards for each row execute function private.check_card_workspace();

create or replace function private.validate_profile() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.default_workspace_id is null then
    select workspace_id into new.default_workspace_id from public.columns where id = new.default_column_id;
    if new.default_workspace_id is null then select id into new.default_workspace_id from public.workspaces order by created_at,id limit 1; end if;
  end if;
  if not exists(select 1 from public.workspaces where id = new.default_workspace_id) then raise exception 'Invalid default workspace'; end if;
  if new.default_column_id is not null and not exists(select 1 from public.columns where id = new.default_column_id and kind = 'project' and workspace_id = new.default_workspace_id) then
    raise exception 'Das Standardprojekt muss zum Start-Workspace gehören.';
  end if;
  return new;
end;
$$;

create or replace function public.set_card_completed(p_card uuid,p_completed boolean) returns void language plpgsql security invoker set search_path = '' as $$
declare current_column uuid; original_project uuid; card_workspace uuid; done_column uuid; target_column uuid;
begin
  if auth.uid() is null or not private.is_member() then raise exception 'Authentication required'; end if;
  if p_completed is null then raise exception 'Completion status required'; end if;
  perform pg_advisory_xact_lock(hashtext('trello-plus-card-order'));
  select column_id,project_id,workspace_id into current_column,original_project,card_workspace from public.cards where id = p_card for update;
  if not found then raise exception 'Card not found'; end if;
  select id into done_column from public.columns where kind = 'done' and workspace_id = card_workspace;
  if done_column is null then raise exception 'Die feste Fertig-Spalte fehlt.'; end if;
  if not p_completed and current_column <> done_column then return; end if;
  target_column := case when p_completed then done_column else original_project end;
  if current_column = target_column then return; end if;
  perform public.move_card(p_card,target_column,null);
end;
$$;
-- Existing function revocations remain; make the intended RPC grant explicit.
revoke all on function public.set_card_completed(uuid,boolean) from public,anon;
grant execute on function public.set_card_completed(uuid,boolean) to authenticated;
alter publication supabase_realtime add table public.workspaces;
