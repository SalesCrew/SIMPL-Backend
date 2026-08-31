-- Trello+ shared workspace. No anonymous access; provisioned members share all cards.
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

create type public.workspace_color as enum ('green','blue','purple','orange','rose','slate');
create table public.columns (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 60),
  color public.workspace_color not null default 'green',
  kind text not null default 'project' check (kind in ('project','work','done')),
  position double precision not null default 0 check (position >= 0 and position < 1000000)
);
create unique index one_done_column on public.columns (kind) where kind = 'done';
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
      if not private.is_admin() then raise exception 'Only admins can mark cards as read'; end if;
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
create function private.validate_column() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.kind <> old.kind and (exists(select 1 from public.cards where column_id = old.id or project_id = old.id) or exists(select 1 from public.profiles where default_column_id = old.id)) then raise exception 'Cannot change kind of a used column'; end if;
  return new;
end;
$$;
revoke all on function private.validate_column() from public,anon,authenticated;
create trigger validate_column before update on public.columns for each row execute function private.validate_column();

insert into public.columns(name,color,kind,position) values
('SPARK','orange','project',0),('ROVER','purple','project',1),('OBI','rose','project',2),('Nespresso','blue','project',3),('In Arbeit','orange','work',4),('Fertig','green','done',5);
insert into public.labels(name,color) values ('Feature','green'),('Verbesserung','blue'),('Bug','rose'),('Feedback','purple'),('Priorität','orange');
alter publication supabase_realtime add table public.cards,public.comments,public.notifications,public.columns,public.labels,public.profiles;
