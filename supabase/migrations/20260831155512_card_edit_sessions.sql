-- Short-lived, owner-private undo journals. Never expose snapshots as tables.
alter table public.cards add column edit_revision bigint not null default 0;
alter table public.cards add column deleted_at timestamptz;
create table private.card_edit_sessions (
  id uuid primary key,
  owner_id uuid not null references public.profiles(id) on delete cascade,
  card_id uuid not null references public.cards(id) on delete cascade,
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  initial_card jsonb not null,
  expected_revision bigint not null,
  conflicted boolean not null default false,
  events jsonb not null default '[]',
  added_comments uuid[] not null default '{}',
  added_attachments uuid[] not null default '{}',
  removed_attachments uuid[] not null default '{}',
  opened_at timestamptz not null default clock_timestamp(),
  closed_at timestamptz,
  expires_at timestamptz not null default clock_timestamp() + interval '15 minutes',
  undoing boolean not null default false
);
create index card_edit_sessions_owner on private.card_edit_sessions(owner_id);
create index card_edit_sessions_card on private.card_edit_sessions(card_id);
create index card_edit_sessions_workspace on private.card_edit_sessions(workspace_id);
create index card_edit_sessions_expiry on private.card_edit_sessions(expires_at);
alter table private.card_edit_sessions enable row level security;
revoke all on private.card_edit_sessions from public,anon,authenticated,service_role;
alter table public.attachments add column edit_session_id uuid;
alter table public.attachments add column held_by_session uuid references private.card_edit_sessions(id) on delete set null;
create index attachments_held_session on public.attachments(held_by_session) where held_by_session is not null;

-- Only server-generated revisions count, including ABA (change, then change back).
create function private.advance_card_edit_revision() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  new.edit_revision := case when tg_op = 'INSERT' then 0 else old.edit_revision + 1 end;
  return new;
end;
$$;
revoke all on function private.advance_card_edit_revision() from public,anon,authenticated;
create trigger advance_edit_revision before insert or update on public.cards
for each row execute function private.advance_card_edit_revision();
create function private.touch_attachment_comment_card() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  -- Pending upload reservations aren't user-visible changes.
  if tg_table_name = 'attachments' then
    if tg_op = 'INSERT' and new.status = 'pending' then return null; end if;
    if tg_op = 'UPDATE' and old.status = new.status then return null; end if;
    if tg_op = 'DELETE' and old.status <> 'ready' then return null; end if;
  end if;
  update public.cards set updated_at = clock_timestamp()
  where id = case when tg_op = 'DELETE' then old.card_id else new.card_id end;
  return null;
end;
$$;
revoke all on function private.touch_attachment_comment_card() from public,anon,authenticated;
create trigger touch_edit_card after insert or update or delete on public.attachments
for each row execute function private.touch_attachment_comment_card();
create trigger touch_edit_card after insert or update or delete on public.comments
for each row execute function private.touch_attachment_comment_card();

-- Deleted cards and their children/files disappear immediately, but remain recoverable.
drop policy member_cards_select on public.cards;
drop policy member_cards_update on public.cards;
drop policy member_cards_delete on public.cards;
create policy member_cards_select on public.cards for select to authenticated
using (deleted_at is null and workspace_id = any((select private.accessible_workspace_ids())::uuid[]));
create policy member_cards_update on public.cards for update to authenticated
using (deleted_at is null and workspace_id = any((select private.accessible_workspace_ids())::uuid[]))
with check (deleted_at is null and workspace_id = any((select private.accessible_workspace_ids())::uuid[]));
create policy member_cards_delete on public.cards for delete to authenticated
using (deleted_at is null and workspace_id = any((select private.accessible_workspace_ids())::uuid[]));
alter policy member_cards_insert on public.cards with check (
  deleted_at is null and workspace_id = any((select private.accessible_workspace_ids())::uuid[]) and created_by = (select auth.uid())
);
create or replace function private.can_access_card(p_card uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.cards c where c.id = p_card and c.deleted_at is null
    and private.user_can_access_workspace(auth.uid(),c.workspace_id));
$$;

-- Ordinary validation still runs on undo. Restore just the two timestamps that
-- the normal card validator deliberately regenerates. The private undoing flag
-- is only true inside the locked undo transaction, never from a caller's input.
create function private.restore_edit_timestamps() returns trigger
language plpgsql security definer set search_path = '' as $$
declare saved jsonb;
begin
  select initial_card into saved from private.card_edit_sessions
  where card_id = new.id and owner_id = auth.uid() and undoing;
  if found then
    new.completed_at := (saved->>'completed_at')::timestamptz;
    new.reviewed_at := (saved->>'reviewed_at')::timestamptz;
    new.reviewed_by := (saved->>'reviewed_by')::uuid;
  end if;
  return new;
end;
$$;
revoke all on function private.restore_edit_timestamps() from public,anon,authenticated;
create trigger zzz_restore_edit_timestamps before update on public.cards
for each row execute function private.restore_edit_timestamps();

-- Discarding history never discards edits. Release retained blobs to the existing
-- retryable Storage cleanup path; no Storage object rows are deleted with SQL.
create function private.release_edit_retention() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.attachments set held_by_session = null,expires_at = clock_timestamp()
  where held_by_session = old.id;
  if exists(select 1 from public.cards where id = old.card_id and deleted_at is not null) then
    update public.attachments set status = 'deleting',expires_at = clock_timestamp()
    where card_id = old.card_id;
  end if;
  return old;
end;
$$;
revoke all on function private.release_edit_retention() from public,anon,authenticated;
create trigger release_retention before delete on private.card_edit_sessions
for each row execute function private.release_edit_retention();

create function private.card_edit_operation(p_session uuid,p_operation text,p_card uuid,
  p_action jsonb,p_actor uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s private.card_edit_sessions; before_card public.cards; after_card public.cards;
  item public.attachments; c public.comments; saved public.cards;
  event_list jsonb := '[]'; field text; kind text := p_action->>'type';
  is_upload boolean := p_operation = 'upload.complete';
begin
  -- A separately granted service-only wrapper calls upload.complete after byte validation.
  if is_upload then
    if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','') <> 'service_role' then
      raise exception 'Upload finalization requires the server' using errcode = '42501';
    end if;
  elsif p_actor is null or p_actor is distinct from auth.uid() then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtext('trello-plus-card-order'));
  if p_operation = 'begin' then
    select * into before_card from public.cards where id = p_card and deleted_at is null for update;
    if not found or not private.user_can_access_workspace(p_actor,before_card.workspace_id) then
      raise exception 'Karte nicht verfügbar.' using errcode = '42501';
    end if;
    if not exists(select 1 from private.card_edit_sessions where id = p_session) then
      if (select count(*) from private.card_edit_sessions where owner_id = p_actor and expires_at > clock_timestamp()) >= 10 then
        raise exception 'Bitte zuerst eine andere Kartenansicht schließen.';
      end if;
      insert into private.card_edit_sessions(id,owner_id,card_id,workspace_id,initial_card,expected_revision)
      values(p_session,p_actor,p_card,before_card.workspace_id,to_jsonb(before_card),before_card.edit_revision);
    end if;
  end if;
  select * into s from private.card_edit_sessions where id = p_session for update;
  if not found or s.owner_id is distinct from p_actor
    or not private.user_can_access_workspace(p_actor,s.workspace_id)
    or (p_card is not null and p_card <> s.card_id) then
    raise exception 'Diese Änderungssitzung ist nicht verfügbar.' using errcode = '42501';
  end if;
  if s.expires_at <= clock_timestamp() then
    raise exception 'Der Zeitraum zum Rückgängigmachen ist abgelaufen.' using errcode = 'P0002';
  end if;
  select * into before_card from public.cards where id = s.card_id for update;
  if not found then raise exception 'Die Karte ist nicht mehr verfügbar.'; end if;

  if p_operation = 'discard' then
    delete from private.card_edit_sessions where id = s.id;
    return jsonb_build_object('id',s.id,'card_id',s.card_id,'events','[]'::jsonb);
  elsif p_operation = 'undo' then
    if s.closed_at is null then raise exception 'Karte zuerst schließen.'; end if;
    if s.conflicted or before_card.edit_revision <> s.expected_revision then
      raise exception 'Die Karte wurde inzwischen anderweitig geändert. Zum Schutz dieser Änderungen ist Rückgängigmachen nicht möglich.' using errcode = '40001';
    end if;
    update private.card_edit_sessions set undoing = true where id = s.id;
    saved := jsonb_populate_record(null::public.cards,s.initial_card);
    -- The retained original blobs become readable again; additions are queued for deletion.
    update public.attachments set status = 'ready',held_by_session = null
      where id = any(s.removed_attachments) and not (id = any(s.added_attachments));
    update public.attachments set status = 'deleting',held_by_session = null,expires_at = clock_timestamp()
      where id = any(s.added_attachments);
    delete from public.comments where id = any(s.added_comments) and author_id = p_actor;
    update public.cards set title = saved.title,description = saved.description,
      assignee_id = saved.assignee_id,label_ids = saved.label_ids,column_id = saved.column_id,
      position = saved.position,completed_at = saved.completed_at,reviewed_at = saved.reviewed_at,
      reviewed_by = saved.reviewed_by,deleted_at = saved.deleted_at where id = s.card_id;
    delete from private.card_edit_sessions where id = s.id;
    return jsonb_build_object('id',s.id,'card_id',s.card_id,'events','[]'::jsonb);
  elsif p_operation = 'close' then
    if s.closed_at is null then
      s.closed_at := clock_timestamp();
      s.expires_at := clock_timestamp() + interval '30 seconds';
    end if;
    if jsonb_array_length(s.events) = 0 then
      delete from private.card_edit_sessions where id = s.id;
      return jsonb_build_object('id',s.id,'card_id',s.card_id,'events','[]'::jsonb);
    end if;
  elsif p_operation in ('hold','offer') then
    if s.closed_at is null then raise exception 'Karte zuerst schließen.'; end if;
    s.expires_at := clock_timestamp() + case when p_operation = 'hold' then interval '90 seconds' else interval '5 seconds' end;
  elsif p_operation in ('begin','touch') then
    if s.closed_at is not null then raise exception 'Diese Kartenansicht ist geschlossen.'; end if;
    s.expires_at := clock_timestamp() + interval '15 minutes';
  elsif p_operation = 'mutate' or is_upload then
    if s.closed_at is not null or before_card.deleted_at is not null then
      raise exception 'Diese Kartenansicht ist geschlossen.';
    end if;
    if jsonb_array_length(s.events) >= 200 then raise exception 'Bitte Karte kurz schließen und erneut öffnen.'; end if;
    if before_card.edit_revision <> s.expected_revision then s.conflicted := true; end if;
    if kind like 'card.%' and (p_action->>'id')::uuid is distinct from s.card_id then
      raise exception 'Ungültige Karte.' using errcode = '42501';
    end if;
    if is_upload then
      select * into item from public.attachments where id = (p_action->>'id')::uuid for update;
      if not found or item.card_id <> s.card_id or item.uploaded_by <> p_actor
        or item.edit_session_id is distinct from s.id or item.status <> 'pending'
        or item.expires_at <= clock_timestamp() then raise exception 'Upload nicht verfügbar.'; end if;
      update public.attachments set status = 'ready' where id = item.id returning * into item;
      s.added_attachments := array_append(s.added_attachments,item.id);
      event_list := jsonb_build_array(jsonb_build_object('field','attachment','before',null,'after',item.filename));
    elsif kind = 'card.update' then
      if jsonb_typeof(p_action->'patch') <> 'object' or exists(
        select 1 from jsonb_object_keys(p_action->'patch') k where k not in ('title','description','assignee_id','label_ids')
      ) then raise exception 'Ungültige Text- oder Karteneigenschaften.'; end if;
      update public.cards set
        title = case when p_action->'patch' ? 'title' then trim(p_action->'patch'->>'title') else title end,
        description = case when p_action->'patch' ? 'description' then p_action->'patch'->>'description' else description end,
        assignee_id = case when p_action->'patch' ? 'assignee_id' then (p_action->'patch'->>'assignee_id')::uuid else assignee_id end,
        label_ids = case when p_action->'patch' ? 'label_ids' then array(select jsonb_array_elements_text(p_action->'patch'->'label_ids'))::uuid[] else label_ids end
      where id = s.card_id;
    elsif kind = 'card.move' then
      if not exists(select 1 from public.columns where id = (p_action->>'column_id')::uuid and workspace_id = s.workspace_id) then
        raise exception 'Die Spalte gehört nicht zu diesem Workspace.';
      end if;
      perform public.move_card(s.card_id,(p_action->>'column_id')::uuid,(p_action->>'before_id')::uuid);
    elsif kind = 'card.complete' then
      perform public.set_card_completed(s.card_id,(p_action->>'completed')::boolean);
    elsif kind = 'card.review' then
      if not private.is_admin() then raise exception 'Nur für Administratoren.' using errcode = '42501'; end if;
      update public.cards set reviewed_at = case when (p_action->>'reviewed')::boolean then clock_timestamp() else null end,
        reviewed_by = case when (p_action->>'reviewed')::boolean then p_actor else null end where id = s.card_id;
    elsif kind = 'card.delete' then
      update public.cards set deleted_at = clock_timestamp() where id = s.card_id;
    elsif kind = 'comment.create' then
      if (p_action->>'card_id')::uuid is distinct from s.card_id then raise exception 'Ungültige Karte.'; end if;
      insert into public.comments(card_id,body) values(s.card_id,trim(p_action->>'body')) returning * into c;
      s.added_comments := array_append(s.added_comments,c.id);
      event_list := jsonb_build_array(jsonb_build_object('field','comment','before',null,'after',c.body));
    elsif kind = 'attachment.delete' then
      select * into item from public.attachments where id = (p_action->>'id')::uuid and card_id = s.card_id and status = 'ready' for update;
      if not found then raise exception 'Anhang nicht verfügbar.'; end if;
      update public.attachments set status = 'deleting',held_by_session = s.id,expires_at = clock_timestamp() where id = item.id;
      s.removed_attachments := array_append(s.removed_attachments,item.id);
      event_list := jsonb_build_array(jsonb_build_object('field','attachment','before',item.filename,'after',null));
    elsif kind = 'attachment.add' then
      -- Already finalized (and journaled) by the validated upload endpoint.
      null;
    else raise exception 'Diese Aktion gehört nicht zur Kartenbearbeitung.'; end if;
    select * into after_card from public.cards where id = s.card_id;
    foreach field in array array['title','description','assignee_id','label_ids','column_id','completed_at','reviewed_at','deleted_at'] loop
      if to_jsonb(before_card)->field is distinct from to_jsonb(after_card)->field then
        event_list := event_list || jsonb_build_array(jsonb_build_object('field',field,'before',to_jsonb(before_card)->field,'after',to_jsonb(after_card)->field));
      end if;
    end loop;
    select coalesce(jsonb_agg(e || jsonb_build_object('at',clock_timestamp())),'[]') into event_list from jsonb_array_elements(event_list) e;
    s.events := s.events || event_list;
    s.expected_revision := after_card.edit_revision;
    s.expires_at := clock_timestamp() + interval '15 minutes';
  else raise exception 'Ungültige Sitzungsaktion.'; end if;
  update private.card_edit_sessions set expected_revision = s.expected_revision,conflicted = s.conflicted,
    events = s.events,added_comments = s.added_comments,added_attachments = s.added_attachments,
    removed_attachments = s.removed_attachments,closed_at = s.closed_at,expires_at = s.expires_at where id = s.id;
  return jsonb_build_object('id',s.id,'card_id',s.card_id,'title',s.initial_card->>'title',
    'opened_at',s.opened_at,'closed_at',s.closed_at,'expires_at',s.expires_at,'events',s.events);
end;
$$;
revoke all on function private.card_edit_operation(uuid,text,uuid,jsonb,uuid) from public,anon;
grant execute on function private.card_edit_operation(uuid,text,uuid,jsonb,uuid) to authenticated,service_role;
grant usage on schema private to service_role;
create function public.card_edit_session(p_session uuid,p_operation text,p_card uuid default null,p_action jsonb default null)
returns jsonb language sql security invoker set search_path = '' as $$
  select private.card_edit_operation(p_session,p_operation,p_card,p_action,auth.uid());
$$;
revoke all on function public.card_edit_session(uuid,text,uuid,jsonb) from public,anon;
grant execute on function public.card_edit_session(uuid,text,uuid,jsonb) to authenticated;
create function public.complete_card_edit_upload(p_session uuid,p_attachment uuid,p_actor uuid)
returns jsonb language sql security invoker set search_path = '' as $$
  select private.card_edit_operation(p_session,'upload.complete',null,jsonb_build_object('id',p_attachment),p_actor);
$$;
revoke all on function public.complete_card_edit_upload(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.complete_card_edit_upload(uuid,uuid,uuid) to service_role;

create function private.expire_card_edit_sessions() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not exists(select 1 from private.card_edit_sessions where expires_at <= clock_timestamp()) then return; end if;
  perform pg_advisory_xact_lock(hashtext('trello-plus-card-order'));
  delete from private.card_edit_sessions where id in (
    select id from private.card_edit_sessions where expires_at <= clock_timestamp() order by expires_at limit 100
  );
end;
$$;
revoke all on function private.expire_card_edit_sessions() from public,anon,authenticated,service_role;
create extension if not exists pg_cron with schema pg_catalog;
select cron.schedule('expire-card-edit-sessions','1 second','select private.expire_card_edit_sessions()');
select cron.schedule('prune-card-edit-job-history','17 * * * *',
  $$delete from cron.job_run_details where jobid in (select jobid from cron.job where jobname in ('expire-card-edit-sessions','prune-card-edit-job-history')) and end_time < now() - interval '1 day'$$);
