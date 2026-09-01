-- Workspace members archive cards through the existing conflict-aware edit
-- session. This keeps access checks, notifications and five-second undo in the
-- same transaction path as every other detailed-card action.
do $migration$
declare original text; updated text;
begin
  select pg_get_functiondef(
    'private.card_edit_operation(uuid,text,uuid,jsonb,uuid)'::regprocedure
  ) into original;

  updated := replace(
    original,
    'if not found or before_card.archived_at is not null then raise exception ''Die Karte ist nicht mehr verfügbar.'' using errcode = ''42501''; end if;',
    'if not found or (before_card.archived_at is not null and p_operation not in (''close'',''hold'',''offer'',''undo'',''discard'')) then raise exception ''Die Karte ist nicht mehr verfügbar.'' using errcode = ''42501''; end if;'
  );
  if updated = original then
    raise exception 'Unexpected archived card edit-session guard';
  end if;
  original := updated;

  updated := replace(
    original,
    '    elsif kind = ''card.delete'' then
      update public.cards set deleted_at = clock_timestamp() where id = s.card_id;',
    '    elsif kind = ''card.archive'' then
      update public.cards set archived_at = clock_timestamp() where id = s.card_id;
    elsif kind = ''card.delete'' then
      update public.cards set deleted_at = clock_timestamp() where id = s.card_id;'
  );
  if updated = original then
    raise exception 'Unexpected card action dispatcher';
  end if;
  original := updated;

  updated := replace(
    original,
    'reviewed_by = saved.reviewed_by,deleted_at = saved.deleted_at where id = s.card_id;',
    'reviewed_by = saved.reviewed_by,archived_at = saved.archived_at,deleted_at = saved.deleted_at where id = s.card_id;'
  );
  if updated = original then
    raise exception 'Unexpected card undo fields';
  end if;
  original := updated;

  updated := replace(
    original,
    '''completed_at'',''reviewed_at'',''deleted_at''',
    '''completed_at'',''reviewed_at'',''archived_at'',''deleted_at'''
  );
  if updated = original then
    raise exception 'Unexpected card edit event fields';
  end if;

  execute updated;
end;
$migration$;
