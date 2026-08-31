-- Trello+ shared workspace. No anonymous access; provisioned members share all cards.
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

create type public.workspace_color as enum ('green','blue','purple','orange','rose','slate','mint','sage','teal','sky','periwinkle','lavender','pink','peach','butter','sand');
create table public.columns (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 60),
  color public.workspace_color not null default 'green',
  kind text not null default 'project' check (kind in ('project','work','done')),
  position double precision not null default 0 check (position >= 0 and position < 1000000)
);
create unique index one_done_column on public.columns (kind) where kind = 'done';
create unique index one_work_column on public.columns (kind) where kind = 'work';
alter table public.columns add constraint fixed_status_names check (
  (kind = 'work' and name = 'In Arbeit') or
  (kind = 'done' and name = 'Fertig') or
  (kind = 'project' and lower(trim(name)) not in ('in arbeit','fertig'))
);
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 100),
  email text not null unique,
  role text not null default 'mitarbeiter' check (role in ('admin','mitarbeiter')),
  default_column_id uuid references public.columns(id) on delete restrict,
  color public.workspace_color not null default 'green',
  active boolean not null default true
);
create index profiles_default_column on public.profiles(default_column_id);
create table public.labels (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 40),
  color public.workspace_color not null default 'green'
);
create unique index labels_unique_name on public.labels(lower(name));
create table public.cards (
  id uuid primary key default gen_random_uuid(),
  title text not null check(length(trim(title)) between 1 and 180),
  description text not null default '' check(length(description) <= 20000),
  column_id uuid not null references public.columns(id) on delete restrict,
  project_id uuid not null references public.columns(id) on delete restrict,
  created_by uuid not null default auth.uid() references public.profiles(id) on delete restrict,
  assignee_id uuid references public.profiles(id) on delete set null,
  label_ids uuid[] not null default '{}' check(cardinality(label_ids) <= 30),
  position double precision not null default 0,
  completed_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index cards_column_position on public.cards(column_id,position);
create index cards_project on public.cards(project_id);
create index cards_creator on public.cards(created_by);
create index cards_assignee on public.cards(assignee_id);
create index cards_reviewer on public.cards(reviewed_by);
create table public.comments (
  id uuid primary key default gen_random_uuid(),
  card_id uuid not null references public.cards(id) on delete cascade,
  author_id uuid not null default auth.uid() references public.profiles(id) on delete restrict,
  body text not null check(length(trim(body)) between 1 and 5000),
  created_at timestamptz not null default now()
);
create index comments_card_time on public.comments(card_id,created_at);
create index comments_author on public.comments(author_id);
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  actor_id uuid not null references public.profiles(id) on delete cascade,
  card_id uuid not null references public.cards(id) on delete cascade,
  comment_id uuid not null references public.comments(id) on delete cascade,
  body text not null,
  created_at timestamptz not null default now(),
  seen_at timestamptz,
  unique(recipient_id,comment_id)
);
create index notifications_recipient_time on public.notifications(recipient_id,created_at desc);
create index notifications_actor on public.notifications(actor_id);
create index notifications_card on public.notifications(card_id);
create index notifications_comment on public.notifications(comment_id);

-- Private fixed-purpose lookups avoid recursive profile RLS. Authorization never uses user_metadata.
create function private.is_member() returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and exists(select 1 from public.profiles where id = auth.uid() and active);
$$;
create function private.is_admin() returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and exists(select 1 from public.profiles where id = auth.uid() and active and role = 'admin');
$$;
revoke all on function private.is_member(), private.is_admin() from public, anon;
grant execute on function private.is_member(), private.is_admin() to authenticated;

alter table public.columns enable row level security;
alter table public.profiles enable row level security;
alter table public.labels enable row level security;
alter table public.cards enable row level security;
alter table public.comments enable row level security;
alter table public.notifications enable row level security;
revoke all on public.columns,public.profiles,public.labels,public.cards,public.comments,public.notifications from anon,authenticated;
grant select on public.columns,public.profiles,public.labels,public.cards,public.comments,public.notifications to authenticated;
grant insert,update,delete on public.columns,public.labels,public.cards to authenticated;
grant insert on public.comments to authenticated;
grant update(seen_at) on public.notifications to authenticated;
grant all on public.columns,public.profiles,public.labels,public.cards,public.comments,public.notifications to service_role;

create policy member_profiles on public.profiles for select to authenticated using ((select private.is_member()));
create policy member_columns on public.columns for select to authenticated using ((select private.is_member()));
create policy admin_columns_insert on public.columns for insert to authenticated with check ((select private.is_admin()));
create policy admin_columns_update on public.columns for update to authenticated using ((select private.is_admin())) with check ((select private.is_admin()));
create policy admin_columns_delete on public.columns for delete to authenticated using ((select private.is_admin()));
create policy member_labels_select on public.labels for select to authenticated using ((select private.is_member()));
create policy member_labels_insert on public.labels for insert to authenticated with check ((select private.is_member()));
create policy member_labels_update on public.labels for update to authenticated using ((select private.is_member())) with check ((select private.is_member()));
-- Labels can be renamed/recolored but not deleted while cards refer to their stable IDs.
create policy member_cards_select on public.cards for select to authenticated using ((select private.is_member()));
create policy member_cards_insert on public.cards for insert to authenticated with check ((select private.is_member()) and created_by = (select auth.uid()));
create policy member_cards_update on public.cards for update to authenticated using ((select private.is_member())) with check ((select private.is_member()));
create policy member_cards_delete on public.cards for delete to authenticated using ((select private.is_member()));
create policy member_comments_select on public.comments for select to authenticated using ((select private.is_member()));
create policy member_comments_insert on public.comments for insert to authenticated with check ((select private.is_member()) and author_id = (select auth.uid()));
create policy own_notifications_select on public.notifications for select to authenticated using ((select private.is_member()) and recipient_id = (select auth.uid()));
create policy own_notifications_update on public.notifications for update to authenticated using ((select private.is_member()) and recipient_id = (select auth.uid())) with check ((select private.is_member()) and recipient_id = (select auth.uid()));

create function private.validate_card() returns trigger language plpgsql set search_path = '' as $$
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
    if new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at or new.project_id is distinct from old.project_id then
      raise exception 'Creator and original project cannot be changed';
    end if;
    if new.reviewed_at is distinct from old.reviewed_at or new.reviewed_by is distinct from old.reviewed_by then
      if auth.uid() is null or not private.is_member() then raise exception 'Authentication required' using errcode = '42501'; end if;
      new.reviewed_by := case when new.reviewed_at is null then null else auth.uid() end;
      new.reviewed_at := case when new.reviewed_at is null then null else now() end;
    end if;
  end if;
  if not exists(select 1 from public.columns where id = new.project_id and kind = 'project') then raise exception 'Invalid original project'; end if;
  if exists(select 1 from unnest(new.label_ids) x where x is null or not exists(select 1 from public.labels where id = x)) then raise exception 'Invalid label'; end if;
  if new.assignee_id is not null and (tg_op = 'INSERT' or new.assignee_id is distinct from old.assignee_id) and not exists(select 1 from public.profiles where id = new.assignee_id and active) then raise exception 'Invalid assignee'; end if;
  select kind into target_kind from public.columns where id = new.column_id;
  new.completed_at := case when target_kind = 'done' then coalesce(case when tg_op = 'UPDATE' then old.completed_at end,now()) else null end;
  new.updated_at := now();
  return new;
end;
$$;
revoke all on function private.validate_card() from public,anon,authenticated;
create trigger validate_card before insert or update on public.cards for each row execute function private.validate_card();

create function public.move_card(p_card uuid,p_column uuid,p_before uuid default null) returns void language plpgsql security invoker set search_path = '' as $$
declare next_pos double precision; previous_pos double precision;
begin
  if auth.uid() is null or not private.is_member() then raise exception 'Authentication required'; end if;
  if p_before = p_card then return; end if;
  perform pg_advisory_xact_lock(hashtext('trello-plus-card-order'));
  if not exists(select 1 from public.cards where id = p_card) then raise exception 'Card not found'; end if;
  if not exists(select 1 from public.columns where id = p_column) then raise exception 'Column not found'; end if;
  -- Rebalance positions to prevent floating-point exhaustion after repeated insertions.
  with positions as (select id,row_number() over(order by position,id) * 1024 as pos from public.cards where column_id = p_column and id <> p_card)
  update public.cards c set position = p.pos from positions p where c.id = p.id;
  if p_before is not null then
    select position into next_pos from public.cards where id = p_before and column_id = p_column;
    if next_pos is null then raise exception 'Target card no longer exists in column'; end if;
    select coalesce(max(position),next_pos-2048) into previous_pos from public.cards where column_id = p_column and id <> p_card and position < next_pos;
    next_pos := (previous_pos + next_pos) / 2;
  else
    select coalesce(max(position),0)+1024 into next_pos from public.cards where column_id = p_column and id <> p_card;
  end if;
  update public.cards set column_id = p_column,position = next_pos where id = p_card;
end;
$$;
revoke all on function public.move_card(uuid,uuid,uuid) from public,anon;
grant execute on function public.move_card(uuid,uuid,uuid) to authenticated;

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

create function private.comment_defaults() returns trigger language plpgsql set search_path = '' as $$
begin new.author_id := auth.uid(); new.created_at := now(); return new; end;
$$;
revoke all on function private.comment_defaults() from public,anon,authenticated;
create trigger comment_defaults before insert on public.comments for each row execute function private.comment_defaults();
-- This private trigger is the only notification writer. Recipients cannot forge notifications.
create function private.notify_comment() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or auth.uid() <> new.author_id or not private.is_member() then raise exception 'Invalid comment author'; end if;
  insert into public.notifications(recipient_id,actor_id,card_id,comment_id,body)
  select distinct p.id,new.author_id,new.card_id,new.id,new.body
  from public.profiles p
  where p.active and p.id <> new.author_id and p.id in (
    select created_by from public.cards where id = new.card_id
    union select assignee_id from public.cards where id = new.card_id
    union select author_id from public.comments where card_id = new.card_id
  );
  return new;
end;
$$;
revoke all on function private.notify_comment() from public,anon,authenticated;
create trigger notify_comment after insert on public.comments for each row execute function private.notify_comment();

create function private.validate_profile() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.default_column_id is not null and not exists(select 1 from public.columns where id = new.default_column_id and kind = 'project') then raise exception 'Default column must be a project'; end if;
  return new;
end;
$$;
revoke all on function private.validate_profile() from public,anon,authenticated;
create trigger validate_profile before insert or update on public.profiles for each row execute function private.validate_profile();
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

insert into public.columns(name,color,kind,position) values
('SPARK','orange','project',0),('ROVER','purple','project',1),('OBI','rose','project',2),('Nespresso','blue','project',3),('In Arbeit','orange','work',4),('Fertig','green','done',5);
-- Install after seeding: status buckets cannot be inserted, changed or deleted by the app.
create trigger validate_column before insert or update or delete on public.columns for each row execute function private.validate_column();
insert into public.labels(name,color) values ('Feature','green'),('Verbesserung','blue'),('Bug','rose'),('Feedback','purple'),('Priorität','orange');
alter publication supabase_realtime add table public.cards,public.comments,public.notifications,public.columns,public.labels,public.profiles;

-- Multi-workspace schema extension (part of this fresh-database snapshot).
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

-- Private card files. Client writes reserve metadata through the authenticated API.
create table public.attachments (
  id uuid primary key default gen_random_uuid(),
  card_id uuid not null references public.cards(id) on delete restrict,
  uploaded_by uuid not null references public.profiles(id) on delete restrict,
  filename text not null check (length(filename) between 1 and 180 and filename !~ '[[:cntrl:]/\\]'),
  mime_type text not null,
  size_bytes integer not null check (size_bytes between 1 and 20971520),
  object_path text generated always as (card_id::text || '/' || id::text) stored unique,
  status text not null default 'pending' check (status in ('pending','ready','deleting')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '15 minutes'
);
create index attachments_card_idx on public.attachments(card_id);
create index attachments_uploader_idx on public.attachments(uploaded_by);
create index attachments_cleanup_idx on public.attachments(expires_at) where status <> 'ready';
alter table public.attachments enable row level security;
revoke all on public.attachments from anon, authenticated;
grant select on public.attachments to authenticated;
grant all on public.attachments to service_role;
create policy attachments_read on public.attachments for select to authenticated
using ((select private.is_member()) and (status = 'ready' or uploaded_by = (select auth.uid())));

-- Lock the parent so simultaneous reservations cannot exceed the per-card limit.
create function private.limit_card_attachments() returns trigger language plpgsql
security definer set search_path = '' as $$
begin
  perform 1 from public.cards where id = new.card_id for update;
  if (select count(*) from public.attachments where card_id = new.card_id) >= 20 then
    raise exception 'ATTACHMENT_LIMIT' using errcode = '23514';
  end if;
  return new;
end;
$$;
revoke all on function private.limit_card_attachments() from public, anon, authenticated;
create trigger attachments_limit before insert on public.attachments
for each row execute function private.limit_card_attachments();

-- A shared row lock serializes Storage insertion with cancellation/deletion.
create function private.can_upload_attachment(path text) returns boolean language plpgsql
security definer set search_path = '' as $$
declare a public.attachments;
begin
  if not private.is_member() then return false; end if;
  select * into a from public.attachments where object_path = path for share;
  return coalesce(a.uploaded_by = auth.uid() and a.status = 'pending' and a.expires_at > now(), false);
end;
$$;
revoke all on function private.can_upload_attachment(text) from public, anon;
grant execute on function private.can_upload_attachment(text) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('card-attachments','card-attachments',false,20971520,array[
  'image/png','image/jpeg','image/webp','image/gif','application/pdf',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'text/plain','text/csv','text/markdown','application/zip'
]);
create policy card_attachment_upload on storage.objects for insert to authenticated
with check (bucket_id = 'card-attachments' and private.can_upload_attachment(name));
create policy card_attachment_download on storage.objects for select to authenticated
using (
  bucket_id = 'card-attachments'
  and (select private.is_member())
  and storage.allow_any_operation(array['object.get_authenticated','object.get_authenticated_info'])
  and exists (select 1 from public.attachments a where a.object_path = name
    and (a.status = 'ready' or (a.status = 'pending' and a.uploaded_by = (select auth.uid()))))
);
-- No Storage UPDATE/DELETE or metadata write policy: no overwrites or bypassing finalization.
alter publication supabase_realtime add table public.attachments;

-- NDA boundaries use the live, administrator-managed home workspace, never JWT metadata.
alter table public.workspaces add column isolated boolean not null default false;
create table public.workspace_blocks (
  id uuid primary key default gen_random_uuid(),
  workspace_a uuid not null references public.workspaces(id) on delete cascade,
  workspace_b uuid not null references public.workspaces(id) on delete cascade,
  check (workspace_a < workspace_b),
  unique(workspace_a,workspace_b)
);
create index workspace_blocks_b on public.workspace_blocks(workspace_b);
alter table public.workspace_blocks enable row level security;
revoke all on public.workspace_blocks from public,anon,authenticated;
grant select,insert,update,delete on public.workspace_blocks to authenticated;
grant all on public.workspace_blocks to service_role;
create policy admin_workspace_blocks on public.workspace_blocks for all to authenticated
using ((select private.is_admin())) with check ((select private.is_admin()));

-- Internal only: callers cannot supply another user's identity through any API.
create function private.user_can_access_workspace(p_user uuid,p_workspace uuid) returns boolean
language sql stable security invoker set search_path = '' as $$
  select exists (
    select 1 from public.profiles p
    join public.workspaces home on home.id = p.default_workspace_id
    join public.workspaces target on target.id = p_workspace
    where p.id = p_user and p.active and (
      p.role = 'admin' or home.id = target.id or (
        not home.isolated and not target.isolated and not exists(
          select 1 from public.workspace_blocks b
          where b.workspace_a = least(home.id,target.id) and b.workspace_b = greatest(home.id,target.id)
        )
      )
    )
  );
$$;
revoke all on function private.user_can_access_workspace(uuid,uuid) from public,anon,authenticated,service_role;
create function private.accessible_workspace_ids() returns uuid[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(w.id),'{}'::uuid[]) from public.workspaces w
  where private.user_can_access_workspace(auth.uid(),w.id);
$$;
create function private.can_access_card(p_card uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.cards c where c.id = p_card
    and private.user_can_access_workspace(auth.uid(),c.workspace_id));
$$;
revoke all on function private.accessible_workspace_ids(),private.can_access_card(uuid) from public,anon;
grant execute on function private.accessible_workspace_ids(),private.can_access_card(uuid) to authenticated;

-- Scope existing labels without losing any card associations or copying unrelated custom labels.
alter table public.labels add column workspace_id uuid references public.workspaces(id) on delete restrict;
update public.labels set workspace_id = (select id from public.workspaces order by created_at,id limit 1);
drop index public.labels_unique_name;
create temporary table label_workspace_map on commit drop as
select pairs.*,gen_random_uuid() new_id from (
  select distinct l.id old_id,c.workspace_id
  from public.labels l join public.cards c on l.id = any(c.label_ids)
  where c.workspace_id <> l.workspace_id
) pairs;
insert into public.labels(id,name,color,workspace_id)
select m.new_id,l.name,l.color,m.workspace_id from label_workspace_map m join public.labels l on l.id = m.old_id;
alter table public.cards disable trigger validate_card;
update public.cards c set label_ids = array(
  select coalesce(m.new_id,x.id) from unnest(c.label_ids) with ordinality x(id,ord)
  left join label_workspace_map m on m.old_id = x.id and m.workspace_id = c.workspace_id order by x.ord
) where exists(select 1 from label_workspace_map m where m.workspace_id = c.workspace_id and m.old_id = any(c.label_ids));
alter table public.cards enable trigger validate_card;
alter table public.labels alter column workspace_id set not null;
create unique index labels_workspace_name on public.labels(workspace_id,lower(name));
create function private.validate_label_workspace() returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' and new.workspace_id is null then
    select default_workspace_id into new.workspace_id from public.profiles where id = auth.uid();
  end if;
  if tg_op = 'UPDATE' and (new.workspace_id is distinct from old.workspace_id or new.id is distinct from old.id) then
    raise exception 'Label identity and workspace cannot be changed';
  end if;
  return new;
end;
$$;
revoke all on function private.validate_label_workspace() from public,anon,authenticated;
create trigger validate_label_workspace before insert or update on public.labels
for each row execute function private.validate_label_workspace();
create or replace function private.seed_workspace() returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  insert into public.columns(workspace_id,name,color,kind,position) values
    (new.id,'Allgemein','blue','project',0),(new.id,'In Arbeit','orange','work',1),(new.id,'Fertig','green','done',2);
  insert into public.labels(workspace_id,name,color) values
    (new.id,'Feature','green'),(new.id,'Verbesserung','blue'),(new.id,'Bug','rose'),
    (new.id,'Feedback','purple'),(new.id,'Priorität','orange');
  return new;
end;
$$;

-- Replace, not supplement, every old permissive member policy.
drop policy member_workspaces on public.workspaces;
create policy member_workspaces on public.workspaces for select to authenticated
using (id = any((select private.accessible_workspace_ids())::uuid[]));
drop policy member_profiles on public.profiles;
create policy member_profiles on public.profiles for select to authenticated
using ((select private.is_member()) and (id = (select auth.uid())
  or default_workspace_id = any((select private.accessible_workspace_ids())::uuid[])));
drop policy member_columns on public.columns;
create policy member_columns on public.columns for select to authenticated
using (workspace_id = any((select private.accessible_workspace_ids())::uuid[]));
drop policy member_labels_select on public.labels;
drop policy member_labels_insert on public.labels;
drop policy member_labels_update on public.labels;
create policy member_labels_select on public.labels for select to authenticated
using (workspace_id = any((select private.accessible_workspace_ids())::uuid[]));
create policy member_labels_insert on public.labels for insert to authenticated
with check (workspace_id = any((select private.accessible_workspace_ids())::uuid[]));
create policy member_labels_update on public.labels for update to authenticated
using (workspace_id = any((select private.accessible_workspace_ids())::uuid[]))
with check (workspace_id = any((select private.accessible_workspace_ids())::uuid[]));
drop policy member_cards_select on public.cards;
drop policy member_cards_insert on public.cards;
drop policy member_cards_update on public.cards;
drop policy member_cards_delete on public.cards;
create policy member_cards_select on public.cards for select to authenticated
using (workspace_id = any((select private.accessible_workspace_ids())::uuid[]));
create policy member_cards_insert on public.cards for insert to authenticated
with check (workspace_id = any((select private.accessible_workspace_ids())::uuid[]) and created_by = (select auth.uid()));
create policy member_cards_update on public.cards for update to authenticated
using (workspace_id = any((select private.accessible_workspace_ids())::uuid[]))
with check (workspace_id = any((select private.accessible_workspace_ids())::uuid[]));
create policy member_cards_delete on public.cards for delete to authenticated
using (workspace_id = any((select private.accessible_workspace_ids())::uuid[]));
drop policy member_comments_select on public.comments;
drop policy member_comments_insert on public.comments;
create policy member_comments_select on public.comments for select to authenticated using (private.can_access_card(card_id));
create policy member_comments_insert on public.comments for insert to authenticated
with check (private.can_access_card(card_id) and author_id = (select auth.uid()));
drop policy own_notifications_select on public.notifications;
drop policy own_notifications_update on public.notifications;
create policy own_notifications_select on public.notifications for select to authenticated
using (recipient_id = (select auth.uid()) and private.can_access_card(card_id));
create policy own_notifications_update on public.notifications for update to authenticated
using (recipient_id = (select auth.uid()) and private.can_access_card(card_id))
with check (recipient_id = (select auth.uid()) and private.can_access_card(card_id));
drop policy attachments_read on public.attachments;
create policy attachments_read on public.attachments for select to authenticated
using (private.can_access_card(card_id) and (status = 'ready' or uploaded_by = (select auth.uid()) or (select private.is_admin())));

-- This bounded trigger only validates relations; its arbitrary-user helper stays private.
create function private.check_card_access_relations() returns trigger language plpgsql
security definer set search_path = '' as $$
begin
  if exists(select 1 from unnest(new.label_ids) x where x is null or not exists(
    select 1 from public.labels l where l.id = x and l.workspace_id = new.workspace_id
  )) then raise exception 'Labels must belong to the card workspace'; end if;
  if new.assignee_id is not null and (tg_op = 'INSERT' or new.assignee_id is distinct from old.assignee_id)
    and not private.user_can_access_workspace(new.assignee_id,new.workspace_id)
  then raise exception 'Assignee has no access to this workspace'; end if;
  return new;
end;
$$;
revoke all on function private.check_card_access_relations() from public,anon,authenticated;
-- Run after workspace inference and ordinary card validation.
create trigger zz_card_access_relations before insert or update on public.cards
for each row execute function private.check_card_access_relations();

create or replace function private.notify_comment() returns trigger language plpgsql security definer set search_path = '' as $$
declare card_workspace uuid;
begin
  if auth.uid() is null or auth.uid() <> new.author_id or not private.is_member() then raise exception 'Invalid comment author'; end if;
  select workspace_id into card_workspace from public.cards where id = new.card_id;
  insert into public.notifications(recipient_id,actor_id,card_id,comment_id,body)
  select distinct p.id,new.author_id,new.card_id,new.id,new.body
  from public.profiles p where p.id <> new.author_id
    and private.user_can_access_workspace(p.id,card_workspace) and p.id in (
      select created_by from public.cards where id = new.card_id
      union select assignee_id from public.cards where id = new.card_id
      union select author_id from public.comments where card_id = new.card_id
    );
  return new;
end;
$$;
create or replace function private.can_upload_attachment(path text) returns boolean language plpgsql
security definer set search_path = '' as $$
declare a public.attachments;
begin
  if not private.is_member() then return false; end if;
  select * into a from public.attachments where object_path = path for share;
  return coalesce(a.uploaded_by = auth.uid() and a.status = 'pending' and a.expires_at > now()
    and private.can_access_card(a.card_id),false);
end;
$$;
-- The existing download policy consults attachments RLS, so both bytes and metadata are protected.
drop policy card_attachment_download on storage.objects;
create policy card_attachment_download on storage.objects for select to authenticated using (
  bucket_id = 'card-attachments'
  and storage.allow_any_operation(array['object.get_authenticated','object.get_authenticated_info'])
  and exists(select 1 from public.attachments a where a.object_path = name and
    (a.status = 'ready' or (a.status = 'pending' and (a.uploaded_by = (select auth.uid()) or (select private.is_admin())))))
);

-- Save symmetric policy and workspace details together in one transaction.
create function public.save_workspace(p_id uuid,p_name text,p_color public.workspace_color,
  p_isolated boolean,p_blocked uuid[] default '{}') returns void language plpgsql security invoker set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'Administrator access required' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtext('trello-plus-workspace-access'));
  if p_id is null or p_isolated is null or p_blocked is null or cardinality(p_blocked) > 1000
    or exists(select 1 from unnest(p_blocked) x where x is null or x = p_id or not exists(select 1 from public.workspaces where id = x))
  then raise exception 'Invalid workspace access rules'; end if;
  insert into public.workspaces(id,name,color,isolated) values(p_id,trim(p_name),p_color,p_isolated)
  on conflict(id) do update set name = excluded.name,color = excluded.color,isolated = excluded.isolated;
  delete from public.workspace_blocks where workspace_a = p_id or workspace_b = p_id;
  if not p_isolated then
    insert into public.workspace_blocks(workspace_a,workspace_b)
    select distinct least(p_id,x),greatest(p_id,x) from unnest(p_blocked) x;
  end if;
end;
$$;
revoke all on function public.save_workspace(uuid,text,public.workspace_color,boolean,uuid[]) from public,anon;
grant execute on function public.save_workspace(uuid,text,public.workspace_color,boolean,uuid[]) to authenticated;

-- Realtime carries only the recipient's opaque counters, never business rows or deleted IDs.
create table public.access_revisions (
  id uuid primary key references public.profiles(id) on delete cascade,
  authorization_version bigint not null default 1,
  board_version bigint not null default 1
);
alter table public.access_revisions enable row level security;
revoke all on public.access_revisions from public,anon,authenticated;
grant select on public.access_revisions to authenticated;
grant all on public.access_revisions to service_role;
create policy own_access_revision on public.access_revisions for select to authenticated using (id = (select auth.uid()));
insert into public.access_revisions(id) select id from public.profiles;
create function private.signal_authorization_change() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'profiles' and tg_op = 'INSERT' then
    insert into public.access_revisions(id) values(new.id) on conflict do nothing;
  end if;
  update public.access_revisions set authorization_version = authorization_version + 1,board_version = board_version + 1;
  return null;
end;
$$;
revoke all on function private.signal_authorization_change() from public,anon,authenticated;
create trigger signal_authorization after insert or update or delete on public.profiles
for each row execute function private.signal_authorization_change();
create trigger signal_authorization after insert or update or delete on public.workspaces
for each row execute function private.signal_authorization_change();
create trigger signal_authorization after insert or update or delete on public.workspace_blocks
for each row execute function private.signal_authorization_change();
create function private.signal_board_change() returns trigger language plpgsql security definer set search_path = '' as $$
declare row_data jsonb; workspace uuid;
begin
  row_data := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  if tg_table_name in ('cards','columns','labels') then workspace := (row_data->>'workspace_id')::uuid;
  else select workspace_id into workspace from public.cards where id = (row_data->>'card_id')::uuid;
  end if;
  update public.access_revisions set board_version = board_version + 1
  where private.user_can_access_workspace(id,workspace);
  return null;
end;
$$;
revoke all on function private.signal_board_change() from public,anon,authenticated;
create trigger signal_board after insert or update or delete on public.cards for each row execute function private.signal_board_change();
create trigger signal_board after insert or update or delete on public.columns for each row execute function private.signal_board_change();
create trigger signal_board after insert or update or delete on public.labels for each row execute function private.signal_board_change();
create trigger signal_board after insert or update or delete on public.comments for each row execute function private.signal_board_change();
create trigger signal_board after insert or update or delete on public.notifications for each row execute function private.signal_board_change();
create trigger signal_board after insert or update or delete on public.attachments for each row execute function private.signal_board_change();
alter publication supabase_realtime set table public.access_revisions;
alter publication supabase_realtime set (publish = 'insert, update');

-- First login request. Invoker RLS remains authoritative for every returned row.
create function public.workspace_access_context() returns jsonb language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'profile',(select to_jsonb(p) from public.profiles p where id = auth.uid() and active),
    'workspaces',coalesce((select jsonb_agg(w order by created_at,id) from public.workspaces w),'[]'::jsonb),
    'revision',(select to_jsonb(r) from public.access_revisions r where id = auth.uid())
  );
$$;
revoke all on function public.workspace_access_context() from public,anon;
grant execute on function public.workspace_access_context() to authenticated;

-- Supabase's safeupdate guard also applies inside trigger statements.
create or replace function private.signal_authorization_change() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'profiles' and tg_op = 'INSERT' then
    insert into public.access_revisions(id) values(new.id) on conflict do nothing;
  end if;
  update public.access_revisions set authorization_version = authorization_version + 1,board_version = board_version + 1
  where id is not null;
  return null;
end;
$$;

-- Newly inserted workspaces are not yet in the statement's cached access-ID set.
-- Admin override must also cover INSERT ... ON CONFLICT and nested workspace seeding.
alter policy member_workspaces on public.workspaces using (
  (select private.is_admin()) or id = any((select private.accessible_workspace_ids())::uuid[])
);
alter policy member_columns on public.columns using (
  (select private.is_admin()) or workspace_id = any((select private.accessible_workspace_ids())::uuid[])
);
alter policy member_labels_select on public.labels using (
  (select private.is_admin()) or workspace_id = any((select private.accessible_workspace_ids())::uuid[])
);
alter policy member_labels_insert on public.labels with check (
  (select private.is_admin()) or workspace_id = any((select private.accessible_workspace_ids())::uuid[])
);
alter policy member_labels_update on public.labels using (
  (select private.is_admin()) or workspace_id = any((select private.accessible_workspace_ids())::uuid[])
) with check (
  (select private.is_admin()) or workspace_id = any((select private.accessible_workspace_ids())::uuid[])
);
