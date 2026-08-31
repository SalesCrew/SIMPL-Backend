-- Five visible seconds plus two seconds of transport grace. Preserve all
-- existing session behavior, including concurrent comment-attachment changes.
do $migration$
declare
  original text;
  updated text;
begin
  original := pg_get_functiondef('private.card_edit_operation(uuid,text,uuid,jsonb,uuid)'::regprocedure);
  updated := replace(original,
    'case when p_operation = ''hold'' then interval ''90 seconds'' else interval ''5 seconds'' end',
    'case when p_operation = ''hold'' then interval ''90 seconds'' else interval ''7 seconds'' end');
  if updated = original then
    raise exception 'Unexpected card edit offer lease definition';
  end if;
  execute updated;
end;
$migration$;
