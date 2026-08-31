-- Return the move and all destination position changes from the same transaction.
-- No new authority: move_card and this receipt both run under the caller's RLS.
create function public.move_card_with_receipt(p_card uuid, p_column uuid, p_before uuid default null)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare receipt jsonb;
begin
  perform public.move_card(p_card, p_column, p_before);
  if not exists(select 1 from public.cards where id = p_card and column_id = p_column
    and archived_at is null and deleted_at is null) then
    raise exception 'Move not applied' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(to_jsonb(c) order by c.position,c.id),'[]'::jsonb)
    into receipt from public.cards c where c.column_id = p_column
    and c.archived_at is null and c.deleted_at is null;
  return receipt;
end;
$$;
revoke all on function public.move_card_with_receipt(uuid,uuid,uuid) from public,anon;
grant execute on function public.move_card_with_receipt(uuid,uuid,uuid) to authenticated;
