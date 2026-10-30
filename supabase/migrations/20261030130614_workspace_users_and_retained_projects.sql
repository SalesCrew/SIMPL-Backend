-- Accounts are workspace-bound. Retired projects remain addressable by every
-- historical card, comment, notification, meeting and edit-session reference.
set lock_timeout = '5s';
set statement_timeout = '60s';

alter table public.columns add column archived_at timestamptz;
alter table public.columns add constraint fixed_columns_remain_active
  check (kind = 'project' or archived_at is null);

create table private.profile_workspace_binding_history (
  migration text not null,
  profile_id uuid not null,
  workspace_id uuid not null,
  workspace_name text not null,
  previous_project_id uuid,
  previous_project_name text,
  profile_snapshot jsonb not null,
  history_fingerprint jsonb not null,
  history_verified boolean not null default false,
  migrated_at timestamptz not null default clock_timestamp(),
  primary key (migration, profile_id)
);
alter table private.profile_workspace_binding_history enable row level security;
revoke all on private.profile_workspace_binding_history from public, anon, authenticated, service_role;
comment on table private.profile_workspace_binding_history is
  'Private pre-backfill snapshots. No business identity, role, home workspace or history is recreated.';

create or replace function private.validate_profile() returns trigger
language plpgsql set search_path = '' as $$
begin
  -- Retain compatibility with old clients that supplied only a default project:
  -- infer its workspace first, then discard the deprecated project preference.
  if new.default_workspace_id is null then
    select workspace_id into new.default_workspace_id from public.columns where id = new.default_column_id;
    if new.default_workspace_id is null then
      select id into new.default_workspace_id from public.workspaces order by created_at,id limit 1;
    end if;
  end if;
  if not exists(select 1 from public.workspaces where id = new.default_workspace_id) then
    raise exception 'Invalid default workspace';
  end if;
  new.default_column_id := null;
  return new;
end;
$$;
revoke all on function private.validate_profile() from public, anon, authenticated;

-- Backfill active AND inactive Development profiles. Save the old mapping before
-- clearing it, and verify that identity, roles, access and business data match.
do $$
declare target uuid; before_profiles jsonb; before_access jsonb; before_history jsonb; after_history jsonb;
begin
  select id into strict target from public.workspaces where name = 'Development';
  lock table public.profiles in share row exclusive mode;
  lock table public.cards, public.comments, public.attachments, public.notifications,
    public.personal_meeting_sections, private.card_edit_sessions in share mode;
  select jsonb_agg(to_jsonb(p)-'default_column_id' order by p.id) into before_profiles from public.profiles p;
  select jsonb_agg(jsonb_build_array(p.id, private.user_can_access_workspace(p.id,target)) order by p.id)
    into before_access from public.profiles p;
  select jsonb_build_object(
    'cards',(select md5(coalesce(jsonb_agg(to_jsonb(c) order by c.id)::text,'[]')) from public.cards c where c.workspace_id=target),
    'comments',(select md5(coalesce(jsonb_agg(to_jsonb(x) order by x.id)::text,'[]')) from public.comments x join public.cards c on c.id=x.card_id where c.workspace_id=target),
    'attachments',(select md5(coalesce(jsonb_agg(to_jsonb(x) order by x.id)::text,'[]')) from public.attachments x join public.cards c on c.id=x.card_id where c.workspace_id=target),
    'notifications',(select md5(coalesce(jsonb_agg(to_jsonb(x) order by x.id)::text,'[]')) from public.notifications x where x.workspace_id=target),
    'edits',(select md5(coalesce(jsonb_agg(to_jsonb(x) order by x.id)::text,'[]')) from private.card_edit_sessions x join public.cards c on c.id=x.card_id where c.workspace_id=target),
    'meetings',(select md5(coalesce(jsonb_agg(to_jsonb(x) order by x.meeting_id,x.section_id)::text,'[]')) from public.personal_meeting_sections x join public.columns c on c.id=x.project_id where c.workspace_id=target)
  ) into before_history;

  insert into private.profile_workspace_binding_history
    (migration,profile_id,workspace_id,workspace_name,previous_project_id,previous_project_name,profile_snapshot,history_fingerprint)
  select 'workspace_users_and_retained_projects',p.id,p.default_workspace_id,w.name,p.default_column_id,c.name,to_jsonb(p),before_history
  from public.profiles p join public.workspaces w on w.id=p.default_workspace_id
  left join public.columns c on c.id=p.default_column_id
  where p.default_workspace_id=target;

  update public.profiles set default_column_id=null where default_workspace_id=target and default_column_id is not null;
  if before_profiles is distinct from (select jsonb_agg(to_jsonb(p)-'default_column_id' order by p.id) from public.profiles p) then
    raise exception 'Workspace backfill changed profile identity, role or home workspace';
  end if;
  if before_access is distinct from (select jsonb_agg(jsonb_build_array(p.id,private.user_can_access_workspace(p.id,target)) order by p.id) from public.profiles p) then
    raise exception 'Workspace backfill changed access';
  end if;
  select jsonb_build_object(
    'cards',(select md5(coalesce(jsonb_agg(to_jsonb(c) order by c.id)::text,'[]')) from public.cards c where c.workspace_id=target),
    'comments',(select md5(coalesce(jsonb_agg(to_jsonb(x) order by x.id)::text,'[]')) from public.comments x join public.cards c on c.id=x.card_id where c.workspace_id=target),
    'attachments',(select md5(coalesce(jsonb_agg(to_jsonb(x) order by x.id)::text,'[]')) from public.attachments x join public.cards c on c.id=x.card_id where c.workspace_id=target),
    'notifications',(select md5(coalesce(jsonb_agg(to_jsonb(x) order by x.id)::text,'[]')) from public.notifications x where x.workspace_id=target),
    'edits',(select md5(coalesce(jsonb_agg(to_jsonb(x) order by x.id)::text,'[]')) from private.card_edit_sessions x join public.cards c on c.id=x.card_id where c.workspace_id=target),
    'meetings',(select md5(coalesce(jsonb_agg(to_jsonb(x) order by x.meeting_id,x.section_id)::text,'[]')) from public.personal_meeting_sections x join public.columns c on c.id=x.project_id where c.workspace_id=target)
  ) into after_history;
  if before_history is distinct from after_history then raise exception 'Workspace backfill changed historical data'; end if;
  update private.profile_workspace_binding_history set history_verified=true
    where migration='workspace_users_and_retained_projects';
end;
$$;

create function private.guard_project_retention() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op='DELETE' then
    if old.archived_at is not null then raise exception 'Entfernte Projekte bleiben für die Historie erhalten.'; end if;
    return old;
  end if;
  if new.archived_at is not null and old.archived_at is null then
    perform pg_advisory_xact_lock(hashtext('trello-plus-card-order'));
    if exists(select 1 from public.cards where column_id=new.id and archived_at is null and deleted_at is null) then
      raise exception 'Bitte zuerst die aktiven Karten aus dieser Projektspalte verschieben.';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function private.guard_project_retention() from public, anon, authenticated;
create trigger zz_project_retention before update or delete on public.columns
  for each row execute function private.guard_project_retention();

create function private.guard_active_project_target() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op='INSERT' or new.column_id is distinct from old.column_id or new.project_id is distinct from old.project_id then
    perform pg_advisory_xact_lock(hashtext('trello-plus-card-order'));
    if exists(select 1 from public.columns where id=new.column_id and archived_at is not null)
      or ((tg_op='INSERT' or new.project_id is distinct from old.project_id)
        and exists(select 1 from public.columns where id=new.project_id and archived_at is not null)) then
      raise exception 'Dieses Projekt wurde aus dem aktiven Board entfernt. Bitte ein aktives Projekt wählen.';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function private.guard_active_project_target() from public, anon, authenticated;
create trigger aa_active_project_target before insert or update on public.cards
  for each row execute function private.guard_active_project_target();

create function public.archive_project(p_project uuid) returns public.columns
language plpgsql security invoker set search_path = '' as $$
declare result public.columns;
begin
  if auth.uid() is null or not private.is_admin() then
    raise exception 'Administrator-Zugriff erforderlich.' using errcode='42501';
  end if;
  perform pg_advisory_xact_lock(hashtext('trello-plus-card-order'));
  select * into result from public.columns where id=p_project for update;
  if not found then raise exception 'Projekt nicht gefunden.'; end if;
  if result.kind<>'project' then raise exception 'In Arbeit und Fertig bleiben als feste Spalten erhalten.'; end if;
  update public.columns set archived_at=coalesce(archived_at,clock_timestamp()) where id=p_project returning * into result;
  return result;
end;
$$;
revoke all on function public.archive_project(uuid) from public, anon;
grant execute on function public.archive_project(uuid) to authenticated;

-- Reopening a task whose original project was removed must never move it into a
-- hidden column. Keep its project/return metadata and use the visible work bucket.
create or replace function public.set_card_completed(p_card uuid,p_completed boolean)
returns void language plpgsql security invoker set search_path = '' as $$
declare c public.cards; done_column uuid; target_column uuid; before_card uuid; previous_card public.cards;
begin
  if auth.uid() is null or not private.is_member() then raise exception 'Authentication required'; end if;
  if p_completed is null then raise exception 'Completion status required'; end if;
  perform pg_advisory_xact_lock(hashtext('trello-plus-card-order'));
  select * into c from public.cards where id=p_card for update;
  if not found then raise exception 'Card not found'; end if;
  select id into done_column from public.columns where kind='done' and workspace_id=c.workspace_id;
  if done_column is null then raise exception 'Die feste Fertig-Spalte fehlt.'; end if;
  if (p_completed and c.column_id=done_column) or (not p_completed and c.column_id<>done_column) then return; end if;
  if p_completed then perform public.move_card(p_card,done_column,null); return; end if;
  select id into target_column from public.columns where id=c.return_column_id and workspace_id=c.workspace_id and kind='project' and archived_at is null;
  if target_column is null then
    select id into target_column from public.columns where id=c.project_id and workspace_id=c.workspace_id and kind='project' and archived_at is null;
  end if;
  if target_column is null then
    select id into target_column from public.columns where kind='work' and workspace_id=c.workspace_id;
  end if;
  if target_column is null then raise exception 'Die feste In-Arbeit-Spalte fehlt.'; end if;
  select id into before_card from public.cards where id=c.return_before_id and column_id=target_column and deleted_at is null and archived_at is null;
  if before_card is null then
    select * into previous_card from public.cards where id=c.return_after_id and column_id=target_column and deleted_at is null and archived_at is null;
    if found then
      select id into before_card from public.cards where column_id=target_column and deleted_at is null and archived_at is null
        and (position,id)>(previous_card.position,previous_card.id) order by position,id limit 1;
    elsif c.return_index is not null then
      select id into before_card from public.cards where column_id=target_column and deleted_at is null and archived_at is null
        order by position,id offset c.return_index limit 1;
    end if;
  end if;
  perform public.move_card(p_card,target_column,before_card);
end;
$$;
revoke all on function public.set_card_completed(uuid,boolean) from public, anon;
grant execute on function public.set_card_completed(uuid,boolean) to authenticated;
