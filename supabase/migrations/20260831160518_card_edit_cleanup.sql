-- Scoped, retryable cleanup after an undo offer is resolved. Stored bytes always
-- go through Storage's API before the metadata/card can be physically removed.
create function private.card_edit_cleanup(p_card uuid,p_purge boolean) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if p_purge then
    if coalesce(current_setting('request.jwt.claims',true)::jsonb->>'role','') <> 'service_role' then
      raise exception 'Server cleanup only' using errcode = '42501';
    end if;
    perform pg_advisory_xact_lock(hashtext('trello-plus-card-order'));
    delete from public.cards c where c.id = p_card and c.deleted_at is not null
      and not exists(select 1 from private.card_edit_sessions s where s.card_id = c.id)
      and not exists(select 1 from public.attachments a where a.card_id = c.id);
    return found;
  end if;
  return auth.uid() is not null and exists(select 1 from public.cards c where c.id = p_card
    and private.user_can_access_workspace(auth.uid(),c.workspace_id));
end;
$$;
revoke all on function private.card_edit_cleanup(uuid,boolean) from public,anon;
grant execute on function private.card_edit_cleanup(uuid,boolean) to authenticated,service_role;
create function public.card_edit_cleanup(p_card uuid,p_purge boolean default false) returns boolean
language sql security invoker set search_path = '' as $$ select private.card_edit_cleanup(p_card,p_purge); $$;
revoke all on function public.card_edit_cleanup(uuid,boolean) from public,anon;
grant execute on function public.card_edit_cleanup(uuid,boolean) to authenticated,service_role;
