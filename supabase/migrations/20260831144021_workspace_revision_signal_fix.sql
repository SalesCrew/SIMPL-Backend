-- Supabase's safeupdate guard also applies inside trigger statements.
create or replace function private.signal_authorization_change() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'profiles' and tg_op = 'INSERT' then
    insert into public.access_revisions(id) values(new.id) on conflict do nothing;
  end if;
  update public.access_revisions set authorization_version = authorization_version + 1,board_version = board_version + 1
  where id is not null;
  return null;
end;
$$;
