-- Acknowledgements are shared card state, available to every active role.
-- Preserve RLS, workspace/owner checks, undo behavior, grants and server-owned
-- reviewed_by/reviewed_at. Patch only the two former administrator restrictions.
do $migration$
declare original text; updated text;
begin
  original := pg_get_functiondef('private.validate_card()'::regprocedure);
  updated := replace(original,
    'if not private.is_admin() then raise exception ''Only admins can mark cards as read''; end if;',
    'if auth.uid() is null or not private.is_member() then raise exception ''Authentication required'' using errcode = ''42501''; end if;');
  if updated = original then raise exception 'Unexpected card acknowledgement guard; migration stopped.'; end if;
  execute updated;

  original := pg_get_functiondef('private.card_edit_operation(uuid,text,uuid,jsonb,uuid)'::regprocedure);
  updated := replace(original,
    'elsif kind = ''card.review'' then
      if not private.is_admin() then raise exception ''Nur für Administratoren.'' using errcode = ''42501''; end if;',
    'elsif kind = ''card.review'' then
      if not private.is_member() then raise exception ''Authentication required'' using errcode = ''42501''; end if;
      if jsonb_typeof(p_action->''reviewed'') is distinct from ''boolean'' then
        raise exception ''Acknowledgement status required'' using errcode = ''22023'';
      end if;');
  if updated = original then raise exception 'Unexpected card acknowledgement session; migration stopped.'; end if;
  execute updated;
end;
$migration$;
