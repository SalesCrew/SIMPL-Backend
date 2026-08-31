-- Entire test is rolled back: no real cards, users, files or notifications are changed.
begin;
do $$
declare u uuid := gen_random_uuid(); other_user uuid := gen_random_uuid(); w uuid := gen_random_uuid();
  project uuid; work uuid; card uuid := gen_random_uuid(); other_card uuid := gen_random_uuid();
  sid uuid := gen_random_uuid(); attachment uuid := gen_random_uuid(); added uuid := gen_random_uuid();
  label uuid; receipt jsonb; baseline jsonb; result jsonb;
begin
  insert into public.workspaces(id,name,color,isolated) values(w,'Undo transaction QA','sage',true);
  select id into project from public.columns where workspace_id = w and kind = 'project';
  select id into work from public.columns where workspace_id = w and kind = 'work';
  select id into label from public.labels where workspace_id = w limit 1;
  insert into auth.users(id,email) values(u,u||'@example.invalid'),(other_user,other_user||'@example.invalid');
  insert into public.profiles(id,email,name,role,default_workspace_id) values
    (u,u||'@example.invalid','Undo QA','admin',w),(other_user,other_user||'@example.invalid','Other QA','mitarbeiter',w);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'role','authenticated')::text,true);
  insert into public.cards(id,title,description,column_id,project_id,workspace_id) values
    (card,'Before','Original description',project,project,w),(other_card,'Untouched','',project,project,w);
  insert into public.attachments(id,card_id,uploaded_by,filename,mime_type,size_bytes,status)
    values(attachment,card,u,'before.txt','text/plain',5,'ready');
  select to_jsonb(c) into baseline from public.cards c where id = card;
  receipt := public.card_edit_session(sid,'begin',card);
  if receipt->>'opened_at' is null then raise exception 'No server timestamp'; end if;
  -- Begin is idempotent and never resets the initial snapshot.
  perform public.card_edit_session(sid,'begin',card);
  perform public.card_edit_session(sid,'mutate',card,jsonb_build_object('type','card.update','id',card,'patch',jsonb_build_object('title','Saved title','description','Saved description','assignee_id',other_user,'label_ids',jsonb_build_array(label))));
  begin
    perform public.card_edit_session(sid,'mutate',card,jsonb_build_object('type','card.update','id',other_card,'patch',jsonb_build_object('title','WRONG')));
    raise exception 'Cross-card mutation was allowed';
  exception when insufficient_privilege then null; end;
  perform public.card_edit_session(sid,'mutate',card,jsonb_build_object('type','card.move','id',card,'column_id',work));
  perform public.card_edit_session(sid,'mutate',card,jsonb_build_object('type','card.complete','id',card,'completed',true));
  perform public.card_edit_session(sid,'mutate',card,jsonb_build_object('type','card.review','id',card,'reviewed',true));
  perform public.card_edit_session(sid,'mutate',card,jsonb_build_object('type','comment.create','card_id',card,'body','Saved comment'));
  perform public.card_edit_session(sid,'mutate',card,jsonb_build_object('type','attachment.delete','id',attachment));
  if not exists(select 1 from public.attachments where id = attachment and status = 'deleting' and held_by_session = sid) then
    raise exception 'Removed attachment was not retained';
  end if;
  insert into public.attachments(id,card_id,uploaded_by,filename,mime_type,size_bytes,edit_session_id)
    values(added,card,u,'added.txt','text/plain',5,sid);
  begin
    perform public.complete_card_edit_upload(sid,added,u);
    raise exception 'Unvalidated upload was accepted';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  perform public.complete_card_edit_upload(sid,added,u);
  perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'role','authenticated')::text,true);
  receipt := public.card_edit_session(sid,'close',card);
  if jsonb_array_length(receipt->'events') < 10 then raise exception 'Missing change events'; end if;
  perform public.card_edit_session(sid,'offer',card);
  if (select expires_at from private.card_edit_sessions where id = sid) not between clock_timestamp() + interval '6 seconds' and clock_timestamp() + interval '7 seconds' then raise exception 'Five-second toast needs a seven-second server lease'; end if;
  perform public.card_edit_session(sid,'hold',card);
  if (select expires_at from private.card_edit_sessions where id = sid) < clock_timestamp() + interval '80 seconds' then raise exception 'Expanded lease missing'; end if;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',other_user,'role','authenticated')::text,true);
  begin
    perform public.card_edit_session(sid,'undo',card);
    raise exception 'Other user could undo';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims',jsonb_build_object('sub',u,'role','authenticated')::text,true);
  perform public.card_edit_session(sid,'undo',card);
  select to_jsonb(c) into result from public.cards c where id = card;
  if (baseline - 'updated_at' - 'edit_revision') is distinct from (result - 'updated_at' - 'edit_revision') then
    raise exception 'Card snapshot did not restore: % vs %',baseline,result;
  end if;
  if exists(select 1 from public.comments where card_id = card) then raise exception 'Comment survived undo'; end if;
  if exists(select 1 from public.notifications where card_id = card) then raise exception 'Comment notification survived undo'; end if;
  if not exists(select 1 from public.attachments where id = attachment and status = 'ready') then raise exception 'Original file not restored'; end if;
  if not exists(select 1 from public.attachments where id = added and status = 'deleting' and held_by_session is null) then raise exception 'Added file not queued for removal'; end if;
  if exists(select 1 from private.card_edit_sessions where id = sid) then raise exception 'Undo history retained'; end if;

  -- Comment files are drafts until Send; sending and undo stay part of this session.
  sid := gen_random_uuid();
  added := gen_random_uuid();
  perform public.card_edit_session(sid,'begin',card);
  insert into public.attachments(id,card_id,uploaded_by,filename,mime_type,size_bytes,status,comment_draft_id)
    values(added,card,u,'message.txt','text/plain',5,'ready',gen_random_uuid());
  perform public.card_edit_session(sid,'mutate',card,jsonb_build_object('type','comment.create','card_id',card,'body','',
    'attachments',jsonb_build_array(jsonb_build_object('id',added))));
  receipt := public.card_edit_session(sid,'close',card);
  if not exists(select 1 from jsonb_array_elements(receipt->'events') e where e->>'field'='comment_attachment' and e->>'after'='message.txt') then
    raise exception 'Message file missing from exact diff';
  end if;
  perform public.card_edit_session(sid,'undo',card);
  if exists(select 1 from public.comments where card_id = card) then raise exception 'Attachment-only message survived undo'; end if;
  if not exists(select 1 from public.attachments where id = added and status = 'deleting' and comment_id is null) then
    raise exception 'Undone message file was not retired';
  end if;

  sid := gen_random_uuid();
  perform public.card_edit_session(sid,'begin',card);
  perform public.card_edit_session(sid,'mutate',card,jsonb_build_object('type','card.delete','id',card));
  if private.can_access_card(card) then raise exception 'Soft-deleted card accessible'; end if;
  perform public.card_edit_session(sid,'close',card);
  perform public.card_edit_session(sid,'undo',card);
  if not private.can_access_card(card) then raise exception 'Deleted card was not restored'; end if;

  sid := gen_random_uuid();
  perform public.card_edit_session(sid,'begin',card);
  perform public.card_edit_session(sid,'mutate',card,jsonb_build_object('type','card.update','id',card,'patch',jsonb_build_object('title','Mine')));
  perform public.card_edit_session(sid,'close',card);
  -- Another editor's write is never overwritten (including ABA with equal final values).
  update public.cards set title = 'Someone else' where id = card;
  update public.cards set title = 'Mine' where id = card;
  begin
    perform public.card_edit_session(sid,'undo',card);
    raise exception 'Concurrent edit was overwritten';
  exception when serialization_failure then null; end;
  perform public.card_edit_session(sid,'discard',card);

  sid := gen_random_uuid();
  perform public.card_edit_session(sid,'begin',card);
  update public.profiles set active = false where id = u;
  begin
    perform public.card_edit_session(sid,'touch',card);
    raise exception 'Revoked owner retained access';
  exception when insufficient_privilege then null; end;
  update public.profiles set active = true where id = u;
  perform public.card_edit_session(sid,'mutate',card,jsonb_build_object('type','attachment.delete','id',attachment));
  perform public.card_edit_session(sid,'close',card);
  update private.card_edit_sessions set expires_at = clock_timestamp() - interval '1 second' where id = sid;
  begin
    perform public.card_edit_session(sid,'undo',card);
    raise exception 'Expired undo succeeded';
  exception when no_data_found then null; end;
  perform private.expire_card_edit_sessions();
  if exists(select 1 from private.card_edit_sessions where id = sid) then raise exception 'Expired snapshot remains'; end if;
  if exists(select 1 from public.attachments where id = attachment and held_by_session is not null) then raise exception 'Expired file retention remains'; end if;

  sid := gen_random_uuid();
  perform public.card_edit_session(sid,'begin',card);
  receipt := public.card_edit_session(sid,'close',card);
  if jsonb_array_length(receipt->'events') <> 0 or exists(select 1 from private.card_edit_sessions where id = sid) then raise exception 'Empty session produced history'; end if;
  if has_table_privilege('authenticated','private.card_edit_sessions','SELECT') or has_table_privilege('anon','private.card_edit_sessions','SELECT') then raise exception 'Snapshots are publicly readable'; end if;
  if has_function_privilege('authenticated','public.complete_card_edit_upload(uuid,uuid,uuid)','EXECUTE') then raise exception 'Upload validation bypass'; end if;
  if has_function_privilege('anon','public.card_edit_session(uuid,text,uuid,jsonb)','EXECUTE') then raise exception 'Anonymous session RPC'; end if;
  perform set_config('test.undo_card',card::text,true);
  update public.cards set deleted_at = clock_timestamp() where id = card;
end;
$$;
set local role authenticated;
do $$ begin
  if exists(select 1 from public.cards where id = current_setting('test.undo_card')::uuid) then raise exception 'RLS exposed a deleted card'; end if;
  if exists(select 1 from public.attachments where card_id = current_setting('test.undo_card')::uuid) then raise exception 'RLS exposed deleted-card files'; end if;
end $$;
reset role;
select 'Card edit sessions: snapshot, changes, undo, files, comments with files, deletion, ownership, expiry, conflicts and RLS passed' as verification;
rollback;
