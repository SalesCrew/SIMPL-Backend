-- Every person controls their own email volume. Preferences are hierarchical:
-- master switch -> event type -> workspace -> original project. Missing rows
-- deliberately mean enabled so this migration preserves existing behaviour.
create table public.email_notification_settings (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  enabled boolean not null default true,
  comment_created boolean not null default true,
  card_created boolean not null default true,
  card_reviewed boolean not null default true,
  card_completed boolean not null default true,
  card_archived boolean not null default true,
  updated_at timestamptz not null default now()
);

create table public.email_notification_workspace_preferences (
  user_id uuid not null references public.profiles(id) on delete cascade,
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  enabled boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key(user_id,workspace_id)
);

create table public.email_notification_project_preferences (
  user_id uuid not null references public.profiles(id) on delete cascade,
  project_id uuid not null references public.columns(id) on delete cascade,
  enabled boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key(user_id,project_id)
);

alter table public.email_notification_settings enable row level security;
alter table public.email_notification_workspace_preferences enable row level security;
alter table public.email_notification_project_preferences enable row level security;

revoke all on public.email_notification_settings,
  public.email_notification_workspace_preferences,
  public.email_notification_project_preferences
  from public,anon,authenticated,service_role;
grant select,insert,update,delete on public.email_notification_settings,
  public.email_notification_workspace_preferences,
  public.email_notification_project_preferences to authenticated;
grant all on public.email_notification_settings,
  public.email_notification_workspace_preferences,
  public.email_notification_project_preferences to service_role;

create policy own_email_notification_settings
on public.email_notification_settings for all to authenticated
using (user_id = (select auth.uid()) and (select private.has_password_access()))
with check (user_id = (select auth.uid()) and (select private.has_password_access()));

create policy own_email_notification_workspaces
on public.email_notification_workspace_preferences for all to authenticated
using (
  user_id = (select auth.uid())
  and (select private.has_password_access())
  and workspace_id = any((select private.accessible_workspace_ids())::uuid[])
)
with check (
  user_id = (select auth.uid())
  and (select private.has_password_access())
  and workspace_id = any((select private.accessible_workspace_ids())::uuid[])
);

create policy own_email_notification_projects
on public.email_notification_project_preferences for all to authenticated
using (
  user_id = (select auth.uid())
  and (select private.has_password_access())
  and exists(select 1 from public.columns c where c.id = project_id and c.kind = 'project')
)
with check (
  user_id = (select auth.uid())
  and (select private.has_password_access())
  and exists(select 1 from public.columns c where c.id = project_id and c.kind = 'project')
);

create function private.seed_email_notification_settings() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.email_notification_settings(user_id) values(new.id)
  on conflict(user_id) do nothing;
  return new;
end;
$$;
revoke all on function private.seed_email_notification_settings()
  from public,anon,authenticated,service_role;
create trigger seed_email_notification_settings after insert on public.profiles
for each row execute function private.seed_email_notification_settings();
insert into public.email_notification_settings(user_id)
select id from public.profiles on conflict(user_id) do nothing;

create function private.validate_email_notification_project() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  if not exists(
    select 1 from public.columns c where c.id = new.project_id and c.kind = 'project'
  ) then
    raise exception 'Email preference target must be an accessible project';
  end if;
  return new;
end;
$$;
revoke all on function private.validate_email_notification_project()
  from public,anon,authenticated,service_role;
create trigger validate_email_notification_project
before insert or update on public.email_notification_project_preferences
for each row execute function private.validate_email_notification_project();

create function private.email_notification_allowed(
  p_recipient uuid,
  p_workspace uuid,
  p_project uuid,
  p_event text
) returns boolean language sql stable security invoker set search_path = '' as $$
  select
    coalesce((
      select s.enabled and case p_event
        when 'comment.created' then s.comment_created
        when 'card.created' then s.card_created
        when 'card.reviewed' then s.card_reviewed
        when 'card.completed' then s.card_completed
        when 'card.archived' then s.card_archived
        else false
      end
      from public.email_notification_settings s
      where s.user_id = p_recipient
    ),true)
    and coalesce((
      select w.enabled
      from public.email_notification_workspace_preferences w
      where w.user_id = p_recipient and w.workspace_id = p_workspace
    ),true)
    and (
      p_project is null or coalesce((
        select p.enabled
        from public.email_notification_project_preferences p
        where p.user_id = p_recipient and p.project_id = p_project
      ),true)
    );
$$;
revoke all on function private.email_notification_allowed(uuid,uuid,uuid,text)
  from public,anon,authenticated,service_role;

alter table public.email_outbox
  add column project_id uuid references public.columns(id) on delete set null;
update public.email_outbox o set project_id = c.project_id
from public.cards c where c.id = o.card_id;
create index email_outbox_project on public.email_outbox(project_id)
  where project_id is not null;

create or replace function private.enqueue_workspace_email() returns trigger
language plpgsql security definer set search_path = '' as $$
declare card_project uuid;
begin
  if new.event_type not in (
    'comment.created','card.created','card.reviewed','card.completed','card.archived'
  ) then
    delete from public.email_outbox
    where notification_id = new.id and sent_at is null and discarded_at is null;
    return new;
  end if;

  select c.project_id into card_project from public.cards c where c.id = new.card_id;
  if not private.email_notification_allowed(
    new.recipient_id,new.workspace_id,card_project,new.event_type
  ) then
    delete from public.email_outbox
    where notification_id = new.id and sent_at is null and discarded_at is null;
    return new;
  end if;

  insert into public.email_outbox(
    notification_id,recipient_id,actor_id,workspace_id,project_id,card_id,comment_id,
    event_type,subject,body,event_created_at
  ) values (
    new.id,new.recipient_id,new.actor_id,new.workspace_id,card_project,new.card_id,new.comment_id,
    new.event_type,new.subject,new.body,new.created_at
  )
  on conflict(notification_id) do update set
    recipient_id = excluded.recipient_id,
    actor_id = excluded.actor_id,
    workspace_id = excluded.workspace_id,
    project_id = excluded.project_id,
    card_id = excluded.card_id,
    comment_id = excluded.comment_id,
    event_type = excluded.event_type,
    subject = excluded.subject,
    body = excluded.body,
    event_created_at = excluded.event_created_at,
    next_attempt_at = clock_timestamp(),
    locked_at = null,
    lease_token = null,
    last_error = null
  where email_outbox.sent_at is null and email_outbox.discarded_at is null;
  return new;
end;
$$;
revoke all on function private.enqueue_workspace_email()
  from public,anon,authenticated,service_role;

drop function public.claim_email_outbox(integer);
create function public.claim_email_outbox(p_limit integer default 20)
returns table (
  outbox_id bigint,
  lease_token uuid,
  notification_id uuid,
  recipient_email text,
  recipient_name text,
  actor_name text,
  workspace_name text,
  workspace_id uuid,
  project_id uuid,
  card_id uuid,
  event_type text,
  subject text,
  body text,
  event_created_at timestamptz,
  attempt_count integer
)
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.email_outbox
  where id in (
    select id from public.email_outbox
    where coalesce(sent_at,discarded_at) < clock_timestamp() - interval '30 days'
    order by coalesce(sent_at,discarded_at),id
    limit 1000
  );

  update public.email_outbox o set
    discarded_at = clock_timestamp(),
    locked_at = null,
    lease_token = null,
    last_error = 'recipient_ineligible'
  where o.sent_at is null and o.discarded_at is null
    and (o.locked_at is null or o.locked_at < clock_timestamp() - interval '5 minutes')
    and (
      o.recipient_id = o.actor_id
      or not exists (
        select 1 from public.profiles p
        where p.id = o.recipient_id and p.active
          and position('@' in p.email) > 1
          and private.user_can_access_workspace(p.id,o.workspace_id)
      )
    );

  update public.email_outbox o set
    discarded_at = clock_timestamp(),
    locked_at = null,
    lease_token = null,
    last_error = 'recipient_preference_disabled'
  where o.sent_at is null and o.discarded_at is null
    and (o.locked_at is null or o.locked_at < clock_timestamp() - interval '5 minutes')
    and not private.email_notification_allowed(
      o.recipient_id,o.workspace_id,o.project_id,o.event_type
    );

  update public.email_outbox o set
    discarded_at = clock_timestamp(),
    locked_at = null,
    lease_token = null,
    last_error = coalesce(o.last_error,'retry_limit_reached')
  where o.sent_at is null and o.discarded_at is null
    and o.attempt_count >= 8
    and (o.locked_at is null or o.locked_at < clock_timestamp() - interval '5 minutes');

  return query
  with candidates as (
    select o.id
    from public.email_outbox o
    join public.profiles recipient on recipient.id = o.recipient_id
    where o.sent_at is null and o.discarded_at is null
      and o.attempt_count < 8
      and o.next_attempt_at <= clock_timestamp()
      and (o.locked_at is null or o.locked_at < clock_timestamp() - interval '5 minutes')
      and o.recipient_id <> o.actor_id
      and recipient.active
      and position('@' in recipient.email) > 1
      and private.user_can_access_workspace(recipient.id,o.workspace_id)
      and private.email_notification_allowed(
        o.recipient_id,o.workspace_id,o.project_id,o.event_type
      )
    order by o.event_created_at,o.id
    for update of o skip locked
    limit least(greatest(coalesce(p_limit,20),1),100)
  ), claimed as (
    update public.email_outbox o set
      locked_at = clock_timestamp(),
      lease_token = gen_random_uuid(),
      attempt_count = o.attempt_count + 1
    from candidates c
    where o.id = c.id
    returning o.*
  )
  select
    claimed.id,
    claimed.lease_token,
    claimed.notification_id,
    recipient.email,
    recipient.name,
    coalesce(actor.name,'Ehemaliges Mitglied'),
    workspace.name,
    claimed.workspace_id,
    claimed.project_id,
    claimed.card_id,
    claimed.event_type,
    claimed.subject,
    claimed.body,
    claimed.event_created_at,
    claimed.attempt_count
  from claimed
  join public.profiles recipient on recipient.id = claimed.recipient_id
  left join public.profiles actor on actor.id = claimed.actor_id
  join public.workspaces workspace on workspace.id = claimed.workspace_id
  order by claimed.event_created_at,claimed.id;
end;
$$;
revoke all on function public.claim_email_outbox(integer)
  from public,anon,authenticated;
grant execute on function public.claim_email_outbox(integer) to service_role;
