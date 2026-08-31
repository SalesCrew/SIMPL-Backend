-- All generated workspaces, users and cards in this test are rolled back.
begin;
insert into auth.users(id,aud,role,email) values
('30000000-0000-4000-8000-000000000001','authenticated','authenticated','workspace-admin@example.invalid'),
('30000000-0000-4000-8000-000000000002','authenticated','authenticated','workspace-member@example.invalid');
insert into public.profiles(id,name,email,role) values
('30000000-0000-4000-8000-000000000001','Workspace QA admin','workspace-admin@example.invalid','admin'),
('30000000-0000-4000-8000-000000000002','Workspace QA member','workspace-member@example.invalid','mitarbeiter');
set local role authenticated;
select set_config('request.jwt.claim.sub','30000000-0000-4000-8000-000000000001',true);
do $$
declare new_workspace uuid;
begin
  insert into public.workspaces(name,color) values('QA workspace transaction','lavender') returning id into new_workspace;
  perform set_config('test.workspace_id',new_workspace::text,true);
  if (select count(*) from public.columns where workspace_id=new_workspace) <> 3 then raise exception 'Missing seeded columns'; end if;
  if (select count(*) from public.columns where workspace_id=new_workspace and kind='done') <> 1 then raise exception 'Missing local Fertig'; end if;
  update public.workspaces set name='QA renamed workspace',color='mint' where id=new_workspace;
  begin
    delete from public.columns where workspace_id=new_workspace and kind='done';
    raise exception 'FAIL fixed column deletion accepted';
  exception when raise_exception then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;
reset role;
update public.profiles set default_workspace_id=current_setting('test.workspace_id')::uuid,
default_column_id=(select id from public.columns where workspace_id=current_setting('test.workspace_id')::uuid and kind='project')
where id='30000000-0000-4000-8000-000000000002';
do $$ begin
  begin
    update public.profiles set default_column_id=(select id from public.columns where name='SPARK') where id='30000000-0000-4000-8000-000000000002';
    raise exception 'FAIL mismatched default project accepted';
  exception when raise_exception then if sqlerrm like 'FAIL%' then raise; end if; end;
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','30000000-0000-4000-8000-000000000002',true);
do $$
declare ws uuid := current_setting('test.workspace_id')::uuid; task uuid; project uuid; local_done uuid; other_project uuid;
begin
  if (select count(*) from public.workspaces) < 2 then raise exception 'Employee cannot see all workspaces'; end if;
  select id into project from public.columns where workspace_id=ws and kind='project';
  select id into local_done from public.columns where workspace_id=ws and kind='done';
  select id into other_project from public.columns where name='SPARK';
  begin
    insert into public.workspaces(name) values('Employee cannot create this');
    raise exception 'FAIL employee workspace creation accepted';
  exception when insufficient_privilege then null; end;
  update public.workspaces set name='Employee cannot rename this' where id=ws;
  if (select name from public.workspaces where id=ws) <> 'QA renamed workspace' then raise exception 'Employee edited workspace'; end if;
  insert into public.cards(title,column_id,project_id) values('Workspace QA card',project,project) returning id into task;
  if (select workspace_id from public.cards where id=task) <> ws then raise exception 'Wrong card workspace'; end if;
  perform public.set_card_completed(task,true);
  if (select column_id from public.cards where id=task) <> local_done then raise exception 'Completion escaped workspace'; end if;
  perform public.set_card_completed(task,false);
  if (select column_id from public.cards where id=task) <> project then raise exception 'Reopen escaped workspace'; end if;
  begin
    perform public.move_card(task,other_project,null);
    raise exception 'FAIL cross-workspace move accepted';
  exception when raise_exception then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin
    insert into public.cards(title,column_id,project_id) values('Mismatched workspace',project,other_project);
    raise exception 'FAIL cross-workspace project accepted';
  exception when raise_exception then if sqlerrm like 'FAIL%' then raise; end if; end;
  -- Assignment is a start preference, never a data access restriction.
  insert into public.cards(title,column_id,project_id) values('Other workspace QA card',other_project,other_project) returning id into task;
  perform public.set_card_completed(task,true);
  if (select workspace_id from public.cards where id=task) = ws then raise exception 'Other workspace inaccessible'; end if;
end $$;
set local role anon;
do $$ begin
  begin perform count(*) from public.workspaces; raise exception 'FAIL anonymous workspace access accepted';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'PASS: admin workspace creation/rename, atomic project/bucket seeding, workspace-scoped completion, assignment consistency, employee cross-workspace collaboration, employee administration denial, anonymous denial' as verification;
rollback;
