-- Keep the session's exact diff list in sync with newly supported message files.
-- The existing comment trigger validates and publishes the server-owned metadata.
do $migration$
declare original text; definition text;
begin
  select pg_get_functiondef('private.card_edit_operation(uuid,text,uuid,jsonb,uuid)'::regprocedure) into original;
  definition := replace(original,
    'event_list := jsonb_build_array(jsonb_build_object(''field'',''comment'',''before'',null,''after'',c.body));',
    'event_list := jsonb_build_array(jsonb_build_object(''field'',''comment'',''before'',null,''after'',c.body));
      event_list := event_list || coalesce((select jsonb_agg(jsonb_build_object(''field'',''comment_attachment'',''before'',null,''after'',a.filename) order by array_position(c.attachment_ids,a.id)) from public.attachments a where a.id = any(c.attachment_ids)),''[]''::jsonb);');
  if definition = original then raise exception 'Unexpected card edit journal; migration stopped.'; end if;
  execute definition;
end;
$migration$;
