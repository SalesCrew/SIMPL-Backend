-- One-time transactional import of the privately staged source snapshot.
-- No business text, personal data, passwords or generated IDs belong in Git.
-- New installations have no staging data and intentionally skip this step.
do $import$
declare
  manifest jsonb;
  card_rows jsonb;
  comment_rows jsonb;
  attachment_rows jsonb;
  label_rows jsonb;
  audit_rows jsonb;
  expected_counts jsonb;
  seed_labels jsonb;
  count_mismatches integer;
begin
  if not exists(select 1 from private.trello_migration_rows where source_kind='pending_import') then return; end if;
  select source_payload->'rows'->0 into strict manifest
    from private.trello_migration_rows
    where source_kind='pending_import' and source_payload->>'kind'='manifest';
  expected_counts:=manifest->'expected';
  if manifest->>'source_sha256' !~ '^[0-9a-f]{64}$' or not exists(
    select 1 from public.workspaces where id=(manifest->>'workspace')::uuid and name='Development'
  ) then raise exception 'Unverified import manifest'; end if;
  if exists(select 1 from public.cards) or exists(select 1 from public.comments)
    or exists(select 1 from public.attachments)
    or exists(select 1 from private.trello_migration_rows where source_kind<>'pending_import') then
    raise exception 'Import requires the verified empty destination; no overwrite is permitted';
  end if;
  -- Workspace creation seeds five standard labels even before any user logs
  -- in. Replace only that exact, unused starter set, preserving its snapshot.
  select coalesce(jsonb_agg(to_jsonb(l)),'[]'::jsonb) into seed_labels from public.labels l;
  if jsonb_array_length(seed_labels)>0 and (
    jsonb_array_length(seed_labels)<>5 or exists(select 1 from public.labels
      where workspace_id<>(manifest->>'workspace')::uuid or (name,color::text) not in (
        ('Feature','green'),('Verbesserung','blue'),('Bug','rose'),('Feedback','purple'),('Priorität','orange')))
    or (select count(distinct name) from public.labels)<>5
  ) then raise exception 'Unexpected existing labels; do not overwrite'; end if;
  if exists(select 1 from public.account_security where not password_change_required or password_changed_at is not null) then
    raise exception 'User activation occurred before import; stop and reconcile';
  end if;
  select jsonb_agg(r) into card_rows from private.trello_migration_rows s cross join lateral jsonb_array_elements(s.source_payload->'rows') r
    where s.source_kind='pending_import' and s.source_payload->>'kind'='cards';
  select jsonb_agg(r) into comment_rows from private.trello_migration_rows s cross join lateral jsonb_array_elements(s.source_payload->'rows') r
    where s.source_kind='pending_import' and s.source_payload->>'kind'='comments';
  select jsonb_agg(r) into attachment_rows from private.trello_migration_rows s cross join lateral jsonb_array_elements(s.source_payload->'rows') r
    where s.source_kind='pending_import' and s.source_payload->>'kind'='attachments';
  select jsonb_agg(r) into label_rows from private.trello_migration_rows s cross join lateral jsonb_array_elements(s.source_payload->'rows') r
    where s.source_kind='pending_import' and s.source_payload->>'kind'='labels';
  select jsonb_agg(r) into audit_rows from private.trello_migration_rows s cross join lateral jsonb_array_elements(s.source_payload->'rows') r
    where s.source_kind='pending_import' and s.source_payload->>'kind'='audit';
  if jsonb_array_length(card_rows) is distinct from (expected_counts->>'cards')::integer
    or jsonb_array_length(comment_rows) is distinct from (expected_counts->>'comments')::integer
    or jsonb_array_length(attachment_rows) is distinct from (expected_counts->>'attachments')::integer
    or jsonb_array_length(label_rows) is distinct from (expected_counts->>'labels')::integer
    or jsonb_array_length(audit_rows) is distinct from (expected_counts->>'audit')::integer then
    raise exception 'Staging incomplete';
  end if;
  if exists(select 1 from jsonb_populate_recordset(null::public.attachments,attachment_rows) a
    where not exists(select 1 from storage.objects o where o.bucket_id='card-attachments'
      and o.name=a.object_path and (o.metadata->>'size')::bigint=a.size_bytes)) then
    raise exception 'An original file is missing from private Storage';
  end if;
  -- Only defaults/side effects that would rewrite historical authors, times,
  -- completion and ordering are suspended. FK/check/workspace validators stay
  -- enabled. DDL and writes roll back together on any failure.
  alter table public.cards disable trigger project_card_creation;
  alter table public.cards disable trigger validate_card;
  alter table public.cards disable trigger advance_edit_revision;
  alter table public.cards disable trigger zz_remember_card_return_location;
  alter table public.comments disable trigger comment_defaults;
  alter table public.comments disable trigger validate_comment_attachments;
  alter table public.comments disable trigger notify_comment;
  alter table public.comments disable trigger touch_edit_card;
  alter table public.attachments disable trigger touch_edit_card;

  delete from public.labels where workspace_id=(manifest->>'workspace')::uuid;
  insert into public.labels select * from jsonb_populate_recordset(null::public.labels,label_rows);
  insert into public.cards select * from jsonb_populate_recordset(null::public.cards,card_rows);
  insert into public.comments select * from jsonb_populate_recordset(null::public.comments,comment_rows);
  insert into public.attachments(id,card_id,uploaded_by,filename,mime_type,size_bytes,status,created_at,expires_at,edit_session_id,held_by_session,comment_id,comment_draft_id)
    select id,card_id,uploaded_by,filename,mime_type,size_bytes,status,created_at,expires_at,edit_session_id,held_by_session,comment_id,comment_draft_id
    from jsonb_populate_recordset(null::public.attachments,attachment_rows);

  alter table public.cards enable trigger project_card_creation;
  alter table public.cards enable trigger validate_card;
  alter table public.cards enable trigger advance_edit_revision;
  alter table public.cards enable trigger zz_remember_card_return_location;
  alter table public.comments enable trigger comment_defaults;
  alter table public.comments enable trigger validate_comment_attachments;
  alter table public.comments enable trigger notify_comment;
  alter table public.comments enable trigger touch_edit_card;
  alter table public.attachments enable trigger touch_edit_card;

  select count(*) into count_mismatches from public.cards actual
    join jsonb_populate_recordset(null::public.cards,card_rows) expected using(id)
    where to_jsonb(actual) is distinct from to_jsonb(expected);
  if count_mismatches<>0 then raise exception 'Card fields changed during import'; end if;
  select count(*) into count_mismatches from public.comments actual
    join jsonb_populate_recordset(null::public.comments,comment_rows) expected using(id)
    where to_jsonb(actual) is distinct from to_jsonb(expected);
  if count_mismatches<>0 then raise exception 'Comment fields changed during import'; end if;
  select count(*) into count_mismatches from public.attachments actual
    join jsonb_populate_recordset(null::public.attachments,attachment_rows) expected using(id)
    where to_jsonb(actual) is distinct from to_jsonb(expected);
  if count_mismatches<>0 then raise exception 'Attachment fields changed during import'; end if;
  if (select count(*) from public.cards)<>(expected_counts->>'cards')::integer
    or (select count(*) from public.comments)<>(expected_counts->>'comments')::integer
    or (select count(*) from public.attachments)<>(expected_counts->>'attachments')::integer then
    raise exception 'Import count mismatch';
  end if;
  insert into private.trello_migration_rows(source_id,source_kind,target_id,source_payload)
    select source_id,source_kind,target_id,source_payload
    from jsonb_to_recordset(audit_rows) as x(source_id text,source_kind text,target_id uuid,source_payload jsonb);
  insert into private.trello_migration_rows(source_id,source_kind,source_payload)
    values('snapshot:'||(manifest->>'source_board'),'snapshot',manifest);
  insert into private.trello_migration_rows(source_id,source_kind,source_payload)
    values('seed-labels:'||(manifest->>'source_board'),'pre_import_backup',seed_labels);
  delete from private.trello_migration_rows where source_kind='pending_import';
end;
$import$;
