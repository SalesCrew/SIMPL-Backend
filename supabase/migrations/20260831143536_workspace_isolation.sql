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
