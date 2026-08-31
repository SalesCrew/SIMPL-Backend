-- Temporary account passwords never grant workspace access. Completion can only
-- be recorded by the server after Auth accepts a genuinely changed password.
create table public.account_security (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  password_change_required boolean not null default true,
  password_changed_at timestamptz,
  reset_version bigint not null default 1,
  change_operation uuid,
  change_started_at timestamptz,
  constraint password_completion_consistent check (
    password_change_required = (password_changed_at is null)
  )
);
alter table public.account_security enable row level security;
revoke all on public.account_security from public, anon, authenticated;
grant select(user_id,password_change_required,password_changed_at) on public.account_security to authenticated;
grant all on public.account_security to service_role;
create policy own_account_security on public.account_security for select to authenticated
using (user_id = (select auth.uid()));

create function private.seed_account_security() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.account_security(user_id) values(new.id);
  return new;
end;
$$;
revoke all on function private.seed_account_security() from public,anon,authenticated;
create trigger seed_account_security after insert on public.profiles
for each row execute function private.seed_account_security();
insert into public.account_security(user_id) select id from public.profiles;

create function private.has_password_access() returns boolean
language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and exists (
    select 1 from public.account_security s
    join public.profiles p on p.id=s.user_id and p.active
    join auth.sessions session on session.user_id=s.user_id
      and session.id=nullif(auth.jwt()->>'session_id','')::uuid
    where s.user_id=auth.uid() and not s.password_change_required
      and s.password_changed_at is not null
      and session.created_at >= s.password_changed_at
      and (session.not_after is null or session.not_after > now())
  );
$$;
revoke all on function private.has_password_access() from public,anon;
grant execute on function private.has_password_access() to authenticated;

create or replace function private.is_member() returns boolean
language sql stable security definer set search_path = '' as $$
  select private.has_password_access();
$$;
create or replace function private.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select private.has_password_access() and exists(
    select 1 from public.profiles where id=auth.uid() and active and role='admin'
  );
$$;
create or replace function private.accessible_workspace_ids() returns uuid[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(w.id),'{}'::uuid[]) from public.workspaces w
  where private.has_password_access() and private.user_can_access_workspace(auth.uid(),w.id);
$$;

-- Restrictive policies compose with, never replace, the existing NDA/RLS rules.
do $$ declare t text; begin
  foreach t in array array['profiles','workspaces','workspace_blocks','columns',
    'labels','cards','comments','attachments','notifications','access_revisions'] loop
    execute format('create policy password_ready on public.%I as restrictive for all to authenticated using ((select private.has_password_access())) with check ((select private.has_password_access()))',t);
  end loop;
end $$;

create function public.account_access_context() returns jsonb
language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'security',(select jsonb_build_object('user_id',s.user_id,
      'password_change_required',s.password_change_required,
      'password_changed_at',s.password_changed_at)
      from public.account_security s where s.user_id=auth.uid()),
    'ready',private.has_password_access()
  );
$$;
revoke all on function public.account_access_context() from public,anon;
grant execute on function public.account_access_context() to authenticated;

-- Lease prevents concurrent first-password submissions across API instances.
create function public.begin_password_change(p_user uuid) returns uuid
language plpgsql security invoker set search_path = '' as $$
declare op uuid := gen_random_uuid(); result uuid;
begin
  update public.account_security set change_operation=op,change_started_at=clock_timestamp()
  where user_id=p_user and password_change_required
    and (change_operation is null or change_started_at < now()-interval '5 minutes')
  returning change_operation into result;
  return result;
end;
$$;
create function public.complete_password_change(p_user uuid,p_operation uuid) returns boolean
language plpgsql security invoker set search_path = '' as $$
begin
  update public.account_security set password_change_required=false,
    password_changed_at=clock_timestamp(),change_operation=null,change_started_at=null
  where user_id=p_user and password_change_required and change_operation=p_operation;
  return found;
end;
$$;
create function public.cancel_password_change(p_user uuid,p_operation uuid) returns void
language sql security invoker set search_path = '' as $$
  update public.account_security set change_operation=null,change_started_at=null
  where user_id=p_user and change_operation=p_operation;
$$;
create function public.require_password_change(p_user uuid) returns void
language sql security invoker set search_path = '' as $$
  update public.account_security set password_change_required=true,password_changed_at=null,
    reset_version=reset_version+1,change_operation=null,change_started_at=null
  where user_id=p_user;
$$;
revoke all on function public.begin_password_change(uuid),
  public.complete_password_change(uuid,uuid), public.cancel_password_change(uuid,uuid),
  public.require_password_change(uuid) from public,anon,authenticated;
grant execute on function public.begin_password_change(uuid),
  public.complete_password_change(uuid,uuid), public.cancel_password_change(uuid,uuid),
  public.require_password_change(uuid) to service_role;
create trigger signal_password_access after insert or update or delete on public.account_security
for each row execute function private.signal_authorization_change();
