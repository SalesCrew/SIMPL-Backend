-- Turn the comment-only bell into a workspace activity feed. Notifications are
-- generated only by private triggers and remain scoped by the same NDA rules as
-- the workspace that produced them.
alter table public.notifications add column workspace_id uuid references public.workspaces(id) on delete cascade;
alter table public.notifications add column event_type text not null default 'comment.created';
alter table public.notifications add column subject text;
alter table public.notifications add column event_key text;

update public.notifications n set
  workspace_id = c.workspace_id,
  subject = c.title,
  event_key = 'comment:' || n.comment_id::text
from public.cards c
where c.id = n.card_id;

alter table public.notifications alter column workspace_id set not null;
alter table public.notifications alter column subject set not null;
alter table public.notifications alter column event_key set not null;
alter table public.notifications alter column card_id drop not null;
alter table public.notifications alter column comment_id drop not null;
alter table public.notifications drop constraint notifications_card_id_fkey;
alter table public.notifications add constraint notifications_card_id_fkey
  foreign key(card_id) references public.cards(id) on delete set null;
alter table public.notifications drop constraint notifications_comment_id_fkey;
alter table public.notifications add constraint notifications_comment_id_fkey
  foreign key(comment_id) references public.comments(id) on delete set null;
alter table public.notifications add constraint notifications_event_type_check check(event_type in (
  'comment.created','card.created','card.updated','card.moved','card.completed','card.reopened',
  'card.archived','card.restored','card.reviewed','card.unreviewed','card.deleted',
  'attachment.added','attachment.removed'
));
alter table public.notifications add constraint notifications_subject_check
  check(length(trim(subject)) between 1 and 180);
alter table public.notifications add constraint notifications_event_key_check
  check(length(event_key) between 1 and 220);
alter table public.notifications add constraint notifications_recipient_event_key_key
  unique(recipient_id,event_key);
create index notifications_workspace_time on public.notifications(workspace_id,created_at desc);

drop policy own_notifications_select on public.notifications;
drop policy own_notifications_update on public.notifications;
create policy own_notifications_select on public.notifications for select to authenticated using (
  recipient_id = (select auth.uid())
  and workspace_id = any((select private.accessible_workspace_ids())::uuid[])
);
create policy own_notifications_update on public.notifications for update to authenticated using (
  recipient_id = (select auth.uid())
  and workspace_id = any((select private.accessible_workspace_ids())::uuid[])
) with check (
  recipient_id = (select auth.uid())
  and workspace_id = any((select private.accessible_workspace_ids())::uuid[])
);

-- One private writer fans an event out to every active person who can access the
-- workspace. Reusing an event key within one transaction consolidates compound
-- operations such as completing and moving a card into one clean notification.
create function private.publish_workspace_notification(
  p_workspace uuid,
  p_actor uuid,
  p_card uuid,
  p_comment uuid,
  p_event_type text,
  p_subject text,
  p_body text,
  p_event_key text
) returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_workspace is null or p_actor is null or p_event_key is null
    or not exists(
      select 1 from public.profiles p
      where p.id = p_actor and p.active
        and private.user_can_access_workspace(p.id,p_workspace)
    ) then
    return;
  end if;

  insert into public.notifications(
    recipient_id,actor_id,workspace_id,card_id,comment_id,event_type,subject,body,event_key
  )
  select p.id,p_actor,p_workspace,p_card,p_comment,p_event_type,
    left(coalesce(nullif(trim(p_subject),''),'Karte'),180),
    left(coalesce(p_body,''),5000),p_event_key
  from public.profiles p
  where p.active and p.id <> p_actor
    and private.user_can_access_workspace(p.id,p_workspace)
  on conflict(recipient_id,event_key) do update set
    actor_id = excluded.actor_id,
    workspace_id = excluded.workspace_id,
    card_id = excluded.card_id,
    comment_id = excluded.comment_id,
    event_type = excluded.event_type,
    subject = excluded.subject,
    body = excluded.body,
    created_at = clock_timestamp(),
    seen_at = null;
end;
$$;
revoke all on function private.publish_workspace_notification(uuid,uuid,uuid,uuid,text,text,text,text)
  from public,anon,authenticated,service_role;

create function private.notify_card_activity() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  event_type text;
  event_body text;
  target_name text;
  moved boolean := false;
begin
  -- Imports and maintenance jobs use the service role and must not impersonate a
  -- person. User actions always carry auth.uid().
  if actor is null then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;

  if tg_op = 'INSERT' then
    perform private.publish_workspace_notification(
      new.workspace_id,actor,new.id,null,'card.created',new.title,'Neue Karte erstellt',
      'card:' || txid_current()::text || ':' || new.id::text
    );
    return new;
  elsif tg_op = 'DELETE' then
    if old.deleted_at is null then
      perform private.publish_workspace_notification(
        old.workspace_id,actor,null,null,'card.deleted',old.title,'Karte gelöscht',
        'card:' || txid_current()::text || ':' || old.id::text
      );
    end if;
    return old;
  end if;

  moved := new.column_id is distinct from old.column_id
    or new.project_id is distinct from old.project_id
    or (
      new.position is distinct from old.position
      and current_setting('simpl.moving_card',true) = new.id::text
    );

  if new.deleted_at is not null and old.deleted_at is null then
    event_type := 'card.deleted'; event_body := 'Karte gelöscht';
  elsif new.deleted_at is null and old.deleted_at is not null then
    event_type := 'card.restored'; event_body := 'Karte wiederhergestellt';
  elsif new.archived_at is not null and old.archived_at is null then
    event_type := 'card.archived'; event_body := 'Karte archiviert';
  elsif new.archived_at is null and old.archived_at is not null then
    event_type := 'card.restored'; event_body := 'Aus dem Archiv wiederhergestellt';
  elsif new.completed_at is not null and old.completed_at is null then
    event_type := 'card.completed'; event_body := 'Als erledigt markiert';
  elsif new.completed_at is null and old.completed_at is not null then
    event_type := 'card.reopened'; event_body := 'Wieder geöffnet';
  elsif new.reviewed_at is not null and old.reviewed_at is null then
    event_type := 'card.reviewed'; event_body := 'Als wahrgenommen markiert';
  elsif new.reviewed_at is null and old.reviewed_at is not null then
    event_type := 'card.unreviewed'; event_body := 'Wahrnehmung entfernt';
  elsif moved then
    event_type := 'card.moved';
    select name into target_name from public.columns where id = new.column_id;
    event_body := case
      when new.column_id is distinct from old.column_id then 'Nach ' || coalesce(target_name,'eine andere Liste') || ' verschoben'
      else 'Position geändert'
    end;
  elsif new.title is distinct from old.title
    or new.description is distinct from old.description
    or new.assignee_id is distinct from old.assignee_id
    or new.label_ids is distinct from old.label_ids
    or new.due_at is distinct from old.due_at
    or new.checklists is distinct from old.checklists then
    event_type := 'card.updated';
    event_body := case
      when new.title is distinct from old.title
        and new.description is not distinct from old.description
        and new.assignee_id is not distinct from old.assignee_id
        and new.label_ids is not distinct from old.label_ids
        and new.due_at is not distinct from old.due_at
        and new.checklists is not distinct from old.checklists then 'Titel geändert'
      when new.description is distinct from old.description
        and new.title is not distinct from old.title
        and new.assignee_id is not distinct from old.assignee_id
        and new.label_ids is not distinct from old.label_ids
        and new.due_at is not distinct from old.due_at
        and new.checklists is not distinct from old.checklists then 'Beschreibung geändert'
      when new.checklists is distinct from old.checklists
        and new.title is not distinct from old.title
        and new.description is not distinct from old.description
        and new.assignee_id is not distinct from old.assignee_id
        and new.label_ids is not distinct from old.label_ids
        and new.due_at is not distinct from old.due_at then 'Checkliste geändert'
      when new.assignee_id is distinct from old.assignee_id
        and new.title is not distinct from old.title
        and new.description is not distinct from old.description
        and new.label_ids is not distinct from old.label_ids
        and new.due_at is not distinct from old.due_at
        and new.checklists is not distinct from old.checklists then 'Zuweisung geändert'
      when new.label_ids is distinct from old.label_ids
        and new.title is not distinct from old.title
        and new.description is not distinct from old.description
        and new.assignee_id is not distinct from old.assignee_id
        and new.due_at is not distinct from old.due_at
        and new.checklists is not distinct from old.checklists then 'Labels geändert'
      when new.due_at is distinct from old.due_at
        and new.title is not distinct from old.title
        and new.description is not distinct from old.description
        and new.assignee_id is not distinct from old.assignee_id
        and new.label_ids is not distinct from old.label_ids
        and new.checklists is not distinct from old.checklists then 'Fälligkeit geändert'
      else 'Karte aktualisiert'
    end;
  else
    return new;
  end if;

  perform private.publish_workspace_notification(
    new.workspace_id,actor,new.id,null,event_type,new.title,event_body,
    'card:' || txid_current()::text || ':' || new.id::text
  );
  return new;
end;
$$;
revoke all on function private.notify_card_activity() from public,anon,authenticated,service_role;
create trigger notify_card_activity after insert or update or delete on public.cards
for each row execute function private.notify_card_activity();

create or replace function private.notify_comment() returns trigger
language plpgsql security definer set search_path = '' as $$
declare card_workspace uuid; card_title text; message text;
begin
  if auth.uid() is null or auth.uid() <> new.author_id or not private.is_member() then
    raise exception 'Invalid comment author';
  end if;
  select workspace_id,title into card_workspace,card_title from public.cards where id = new.card_id;
  message := case when length(trim(new.body)) > 0 then new.body
    else cardinality(new.attachment_ids)::text || ' Datei(en) angehängt' end;
  perform private.publish_workspace_notification(
    card_workspace,new.author_id,new.card_id,new.id,'comment.created',card_title,message,
    'comment:' || new.id::text
  );
  return new;
end;
$$;
revoke all on function private.notify_comment() from public,anon,authenticated,service_role;

create function private.notify_attachment_activity() returns trigger
language plpgsql security definer set search_path = '' as $$
declare actor uuid; card_workspace uuid; card_title text; event_type text; event_body text;
begin
  -- Comment files are represented by the single comment event.
  if new.comment_id is not null or new.comment_draft_id is not null then return new; end if;

  if (tg_op = 'INSERT' and new.status = 'ready')
    or (tg_op = 'UPDATE' and old.status = 'pending' and new.status = 'ready') then
    actor := coalesce(auth.uid(),new.uploaded_by);
    event_type := 'attachment.added'; event_body := new.filename || ' angehängt';
  elsif tg_op = 'UPDATE' and old.status = 'ready' and new.status = 'deleting' then
    actor := auth.uid();
    event_type := 'attachment.removed'; event_body := new.filename || ' entfernt';
  else
    return new;
  end if;

  if actor is null then return new; end if;
  select workspace_id,title into card_workspace,card_title from public.cards where id = new.card_id;
  perform private.publish_workspace_notification(
    card_workspace,actor,new.card_id,null,event_type,card_title,event_body,
    'attachment:' || new.id::text || ':' || event_type
  );
  return new;
end;
$$;
revoke all on function private.notify_attachment_activity() from public,anon,authenticated,service_role;
create trigger notify_attachment_activity after insert or update on public.attachments
for each row execute function private.notify_attachment_activity();

-- Notification changes only need to wake their recipient. Other board events wake
-- every member who can access the event's workspace.
create or replace function private.signal_board_change() returns trigger
language plpgsql security definer set search_path = '' as $$
declare row_data jsonb; workspace uuid;
begin
  row_data := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  if tg_table_name = 'notifications' then
    update public.access_revisions set board_version = board_version + 1
    where id = (row_data->>'recipient_id')::uuid;
    return null;
  elsif tg_table_name in ('cards','columns','labels') then
    workspace := (row_data->>'workspace_id')::uuid;
  else
    select workspace_id into workspace from public.cards where id = (row_data->>'card_id')::uuid;
  end if;
  update public.access_revisions set board_version = board_version + 1
  where private.user_can_access_workspace(id,workspace);
  return null;
end;
$$;
revoke all on function private.signal_board_change() from public,anon,authenticated,service_role;

-- Position rebalancing touches sibling rows. Mark the user's actual drag target so
-- only that card produces an activity event.
do $$
declare original text; definition text;
begin
  select pg_get_functiondef('public.move_card(uuid,uuid,uuid)'::regprocedure) into original;
  if position('simpl.moving_card' in original) = 0 then
    definition := replace(
      original,
      'perform pg_advisory_xact_lock(hashtext(''trello-plus-card-order''));',
      'perform pg_advisory_xact_lock(hashtext(''trello-plus-card-order''));' || E'\n  ' ||
      'perform set_config(''simpl.moving_card'',p_card::text,true);'
    );
    if definition = original then raise exception 'move_card activity hook was not installed'; end if;
    execute definition;
  end if;
end;
$$;

-- A five-second undo must also retract every activity event produced by that edit
-- session, including the restoration update itself.
do $$
declare original text; definition text; needle text; replacement text;
begin
  select pg_get_functiondef('private.card_edit_operation(uuid,text,uuid,jsonb,uuid)'::regprocedure) into original;
  if position('created_at >= s.opened_at' in original) = 0 then
    needle := 'where id = s.card_id;' || E'\n    ' ||
      'delete from private.card_edit_sessions where id = s.id;';
    replacement := 'where id = s.card_id;' || E'\n    ' ||
      'delete from public.notifications where actor_id = p_actor and card_id = s.card_id' || E'\n      ' ||
      'and created_at >= s.opened_at;' || E'\n    ' ||
      'delete from private.card_edit_sessions where id = s.id;';
    definition := replace(original,needle,replacement);
    if definition = original then raise exception 'card edit undo activity cleanup was not installed'; end if;
    execute definition;
  end if;
end;
$$;
