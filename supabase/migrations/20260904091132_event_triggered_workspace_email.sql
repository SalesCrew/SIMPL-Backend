-- Archive events use the same durable, per-recipient outbox as card creation,
-- acknowledgement, completion and comments. Delivery itself is woken by the
-- successful application action; this trigger only preserves the committed job.
alter table public.email_outbox
  drop constraint email_outbox_event_type_check;
alter table public.email_outbox
  add constraint email_outbox_event_type_check check (
    event_type in (
      'comment.created','card.created','card.reviewed','card.completed','card.archived'
    )
  );

create or replace function private.enqueue_workspace_email() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.event_type not in (
    'comment.created','card.created','card.reviewed','card.completed','card.archived'
  ) then
    delete from public.email_outbox
    where notification_id = new.id and sent_at is null and discarded_at is null;
    return new;
  end if;

  insert into public.email_outbox(
    notification_id,recipient_id,actor_id,workspace_id,card_id,comment_id,
    event_type,subject,body,event_created_at
  ) values (
    new.id,new.recipient_id,new.actor_id,new.workspace_id,new.card_id,new.comment_id,
    new.event_type,new.subject,new.body,new.created_at
  )
  on conflict(notification_id) do update set
    recipient_id = excluded.recipient_id,
    actor_id = excluded.actor_id,
    workspace_id = excluded.workspace_id,
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

