-- RLS does not apply inside legacy SECURITY DEFINER edit functions. Gate the
-- actor before any card/session lookup, not just table reads and HTTP routes.
do $migration$
declare original text; updated text;
begin
  original := pg_get_functiondef('private.card_edit_operation(uuid,text,uuid,jsonb,uuid)'::regprocedure);
  updated := replace(original,
    'elsif p_actor is null or p_actor is distinct from auth.uid() then',
    'elsif p_actor is null or p_actor is distinct from auth.uid() or not private.has_password_access() then');
  if updated=original then raise exception 'Unexpected edit-session actor guard'; end if;
  original := updated;
  updated := replace(original,
    'if not found then raise exception ''Die Karte ist nicht mehr verfügbar.''; end if;',
    'if not found or before_card.archived_at is not null then raise exception ''Die Karte ist nicht mehr verfügbar.'' using errcode = ''42501''; end if;');
  if updated=original then raise exception 'Unexpected edit-session card guard'; end if;
  execute updated;

  original := pg_get_functiondef('private.card_edit_cleanup(uuid,boolean)'::regprocedure);
  updated := replace(original,'return auth.uid() is not null and exists',
    'return private.has_password_access() and auth.uid() is not null and exists');
  if updated=original then raise exception 'Unexpected card cleanup access guard'; end if;
  execute updated;
end;
$migration$;
create or replace function private.can_access_card(p_card uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.has_password_access() and exists(
    select 1 from public.cards c where c.id=p_card and c.deleted_at is null
      and private.user_can_access_workspace(auth.uid(),c.workspace_id)
  );
$$;
create policy no_direct_migration_ledger_access on private.trello_migration_rows
for all to authenticated using(false) with check(false);
