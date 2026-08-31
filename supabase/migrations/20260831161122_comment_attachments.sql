-- Message uploads use the existing private bucket. Drafts are owner-private until
-- the comment and all of its validated files are published in one transaction.
alter table public.comments add column attachment_ids uuid[] not null default '{}';
alter table public.comments drop constraint comments_body_check;
alter table public.comments add constraint comments_body_check check (
  length(trim(body)) <= 5000 and cardinality(attachment_ids) <= 10
  and (length(trim(body)) > 0 or cardinality(attachment_ids) > 0)
);
alter table public.attachments add column comment_id uuid references public.comments(id) on delete set null;
alter table public.attachments add column comment_draft_id uuid;
alter table public.attachments add constraint attachments_comment_scope check (comment_id is null or comment_draft_id is null);
create index attachments_comment_idx on public.attachments(comment_id);
create index attachments_draft_idx on public.attachments(comment_draft_id) where comment_draft_id is not null;
create index attachments_draft_expiry_idx on public.attachments(expires_at) where comment_draft_id is not null;

create or replace function private.limit_card_attachments() returns trigger language plpgsql
security definer set search_path = '' as $$
begin
  perform 1 from public.cards where id = new.card_id and deleted_at is null for update;
  if not found then raise exception 'Karte nicht verfügbar.' using errcode = '23514'; end if;
  if new.comment_id is not null then raise exception 'Upload zuerst abschließen.' using errcode = '23514'; end if;
  if new.comment_draft_id is null then
    if (select count(*) from public.attachments where card_id = new.card_id and comment_id is null and comment_draft_id is null) >= 20 then
      raise exception 'ATTACHMENT_LIMIT' using errcode = '23514';
    end if;
  elsif (select count(*) from public.attachments where card_id = new.card_id and comment_draft_id = new.comment_draft_id) >= 10
    or (select count(*) from public.attachments where card_id = new.card_id and uploaded_by = new.uploaded_by and comment_draft_id is not null) >= 30 then
    raise exception 'COMMENT_ATTACHMENT_LIMIT' using errcode = '23514';
  end if;
  return new;
end;
$$;

drop policy attachments_read on public.attachments;
create policy attachments_read on public.attachments for select to authenticated using (
  private.can_access_card(card_id) and (
    (comment_draft_id is null and status = 'ready')
    or uploaded_by = (select auth.uid()) or (select private.is_admin())
  )
);
-- Storage reads already consult attachments RLS. Do not introduce public URLs.
update storage.buckets set allowed_mime_types = array_append(allowed_mime_types,'application/octet-stream')
where id = 'card-attachments' and not ('application/octet-stream' = any(allowed_mime_types));

-- Lock in the same order as edit sessions. All IDs must be unique, ready,
-- unexpired drafts owned by the authenticated sender, on this exact card.
create function private.validate_comment_attachments() returns trigger language plpgsql
security definer set search_path = '' as $$
declare matched integer;
begin
  if auth.uid() is null or new.author_id is distinct from auth.uid() or not private.can_access_card(new.card_id) then
    raise exception 'Nachricht nicht erlaubt.' using errcode = '42501';
  end if;
  if cardinality(new.attachment_ids) = 0 then return new; end if;
  if cardinality(new.attachment_ids) > 10 or array_position(new.attachment_ids,null) is not null
    or cardinality(new.attachment_ids) <> (select count(distinct id) from unnest(new.attachment_ids) id) then
    raise exception 'Ungültige Nachrichtenanhänge.' using errcode = '23514';
  end if;
  perform pg_advisory_xact_lock(hashtext('trello-plus-card-order'));
  perform 1 from public.cards where id = new.card_id for update;
  perform 1 from public.attachments where id = any(new.attachment_ids) order by id for update;
  select count(*) into matched from public.attachments where id = any(new.attachment_ids)
    and card_id = new.card_id and uploaded_by = auth.uid() and status = 'ready'
    and comment_id is null and comment_draft_id is not null and expires_at > clock_timestamp();
  if matched <> cardinality(new.attachment_ids) then
    raise exception 'Diese Dateien sind nicht verfügbar. Bitte erneut anhängen.' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke all on function private.validate_comment_attachments() from public,anon,authenticated,service_role;
create trigger validate_comment_attachments before insert on public.comments
for each row execute function private.validate_comment_attachments();

create function private.publish_comment_attachments() returns trigger language plpgsql
security definer set search_path = '' as $$
begin
  update public.attachments set comment_id = new.id,comment_draft_id = null
  where id = any(new.attachment_ids);
  return new;
end;
$$;
revoke all on function private.publish_comment_attachments() from public,anon,authenticated,service_role;
create trigger attach_comment_files after insert on public.comments
for each row execute function private.publish_comment_attachments();

-- Preserve metadata until the Storage API removes bytes, including comment undo.
create function private.retire_comment_attachments() returns trigger language plpgsql
security definer set search_path = '' as $$
begin
  update public.attachments set status = 'deleting',held_by_session = null,expires_at = clock_timestamp()
  where comment_id = old.id;
  return old;
end;
$$;
revoke all on function private.retire_comment_attachments() from public,anon,authenticated,service_role;
create trigger retire_comment_files before delete on public.comments
for each row execute function private.retire_comment_attachments();

create or replace function private.touch_attachment_comment_card() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'attachments' then
    if tg_op = 'DELETE' then
      if old.status <> 'ready' or old.comment_draft_id is not null then return null; end if;
    else
      if new.comment_draft_id is not null then return null; end if;
      if tg_op = 'INSERT' and new.status = 'pending' then return null; end if;
      if tg_op = 'UPDATE' and old.status = new.status then return null; end if;
    end if;
  end if;
  update public.cards set updated_at = clock_timestamp()
  where id = case when tg_op = 'DELETE' then old.card_id else new.card_id end;
  return null;
end;
$$;

-- Extend the existing journal without changing its locking, authorization or undo.
do $migration$
declare definition text; original text;
begin
  select pg_get_functiondef('private.card_edit_operation(uuid,text,uuid,jsonb,uuid)'::regprocedure) into original;
  definition := replace(original,
    'insert into public.comments(card_id,body) values(s.card_id,trim(p_action->>''body'')) returning * into c;',
    'insert into public.comments(card_id,body,attachment_ids) values(s.card_id,trim(p_action->>''body''),array(select (a->>''id'')::uuid from jsonb_array_elements(coalesce(p_action->''attachments'',''[]''::jsonb)) a)) returning * into c;
      s.added_attachments := s.added_attachments || c.attachment_ids;');
  if definition = original then raise exception 'Unexpected card edit function; migration stopped.'; end if;
  execute definition;
  select pg_get_functiondef('private.notify_comment()'::regprocedure) into original;
  definition := replace(original,'new.id,new.body',
    'new.id,coalesce(nullif(new.body,''''),cardinality(new.attachment_ids)::text || '' Datei(en) angehängt'')');
  if definition = original then raise exception 'Unexpected notification function; migration stopped.'; end if;
  execute definition;
end;
$migration$;
