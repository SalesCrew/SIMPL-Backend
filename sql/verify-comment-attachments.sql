-- Transaction-only NDA check: no fixture records or permission changes survive.
begin;
create temp table comment_file_qa as select gen_random_uuid() as wa,gen_random_uuid() as wb,
  gen_random_uuid() as owner,gen_random_uuid() as outsider,gen_random_uuid() as admin,
  gen_random_uuid() as project,gen_random_uuid() as card,gen_random_uuid() as file;
grant select on comment_file_qa to authenticated;
insert into public.workspaces(id,name,isolated)
select wa,'Message NDA QA ' || wa::text,true from comment_file_qa
union all select wb,'Message NDA QA ' || wb::text,true from comment_file_qa;
insert into auth.users(id,email)
select owner,owner::text || '@example.invalid' from comment_file_qa
union all select outsider,outsider::text || '@example.invalid' from comment_file_qa
union all select admin,admin::text || '@example.invalid' from comment_file_qa;
insert into public.profiles(id,email,name,role,default_workspace_id,active)
select owner,owner::text || '@example.invalid','Message QA owner','mitarbeiter',wa,true from comment_file_qa
union all select outsider,outsider::text || '@example.invalid','Message QA isolated','mitarbeiter',wb,true from comment_file_qa
union all select admin,admin::text || '@example.invalid','Message QA admin','admin',wb,true from comment_file_qa;
insert into public.columns(id,workspace_id,name,kind,color,position)
select project,wa,'Message QA project','project','sage',0 from comment_file_qa;
select set_config('request.jwt.claims',jsonb_build_object('sub',owner,'role','authenticated')::text,true) from comment_file_qa;
insert into public.cards(id,title,column_id,project_id,created_by)
select card,'Message NDA fixture',project,project,owner from comment_file_qa;
insert into public.attachments(id,card_id,uploaded_by,filename,mime_type,size_bytes,comment_draft_id)
select file,card,owner,'NDA.pdf','application/pdf',10,gen_random_uuid() from comment_file_qa;
update public.attachments set status='ready' where id=(select file from comment_file_qa);
insert into public.comments(card_id,body,attachment_ids)
select card,'NDA comment',array[file] from comment_file_qa;

set local role authenticated;
select set_config('request.jwt.claims',jsonb_build_object('sub',outsider,'role','authenticated')::text,true) from comment_file_qa;
do $$ begin
  if exists(select 1 from public.comments where card_id=(select card from comment_file_qa))
    or exists(select 1 from public.attachments where id=(select file from comment_file_qa)) then
    raise exception 'FAIL isolated workspace leaked comment files';
  end if;
end $$;
select set_config('request.jwt.claims',jsonb_build_object('sub',admin,'role','authenticated')::text,true) from comment_file_qa;
do $$ begin
  if not exists(select 1 from public.comments where card_id=(select card from comment_file_qa))
    or not exists(select 1 from public.attachments where id=(select file from comment_file_qa)) then
    raise exception 'FAIL admin cannot inspect isolated workspace';
  end if;
end $$;
select 'PASS: isolated member denied comments/files; admin allowed; all fixtures rolled back' as result;
rollback;
