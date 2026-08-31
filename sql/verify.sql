-- Transaction-scoped integration test. ALL synthetic users/data are rolled back.
begin;
insert into auth.users(id,aud,role,email) values
('10000000-0000-4000-8000-000000000001','authenticated','authenticated','admin-test@example.invalid'),
('10000000-0000-4000-8000-000000000002','authenticated','authenticated','member-test@example.invalid'),
('10000000-0000-4000-8000-000000000003','authenticated','authenticated','unprovisioned-test@example.invalid');
insert into public.profiles(id,name,email,role,default_column_id) values
('10000000-0000-4000-8000-000000000001','Test Admin','admin-test@example.invalid','admin',(select id from public.columns where name='SPARK')),
('10000000-0000-4000-8000-000000000002','Test Member','member-test@example.invalid','mitarbeiter',(select id from public.columns where name='ROVER'));
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000002',true);
insert into public.cards(id,title,column_id,project_id,created_by,assignee_id) values
('20000000-0000-4000-8000-000000000001','Integration Test',(select id from public.columns where name='ROVER'),(select id from public.columns where name='ROVER'),'10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002');
do $$ begin
  if (select count(*) from public.columns) <> 6 then raise exception 'Members must see all six columns'; end if;
  if (select created_by from public.cards where id='20000000-0000-4000-8000-000000000001') <> '10000000-0000-4000-8000-000000000002' then raise exception 'Creator spoofing'; end if;
  begin
    update public.cards set reviewed_at=now() where id='20000000-0000-4000-8000-000000000001';
    raise exception 'FAIL employee review accepted';
  exception when others then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin
    update public.profiles set role='admin' where id=auth.uid();
    raise exception 'FAIL role escalation accepted';
  exception when insufficient_privilege then null; end;
end $$;
select public.move_card('20000000-0000-4000-8000-000000000001',(select id from public.columns where kind='done'));
do $$ begin
  if (select completed_at is null from public.cards where id='20000000-0000-4000-8000-000000000001') then raise exception 'Done state missing'; end if;
  if (select project_id from public.cards where id='20000000-0000-4000-8000-000000000001') <> (select id from public.columns where name='ROVER') then raise exception 'Original project changed'; end if;
end $$;
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',true);
-- Administrator attempts are rolled back, including unexpected successes.
do $$
declare fixed public.columns%rowtype; project_id uuid;
begin
  for fixed in select * from public.columns where kind in ('work','done') loop
    begin
      update public.columns set name='Renamed' where id=fixed.id;
      raise exception 'FAIL fixed bucket rename accepted';
    exception when raise_exception then if sqlerrm like 'FAIL%' then raise; end if; end;
    begin
      update public.columns set color='mint',position=0 where id=fixed.id;
      raise exception 'FAIL fixed bucket appearance change accepted';
    exception when raise_exception then if sqlerrm like 'FAIL%' then raise; end if; end;
    begin
      update public.columns set kind='project' where id=fixed.id;
      raise exception 'FAIL fixed bucket conversion accepted';
    exception when raise_exception then if sqlerrm like 'FAIL%' then raise; end if; end;
    begin
      delete from public.columns where id=fixed.id;
      raise exception 'FAIL fixed bucket deletion accepted';
    exception when raise_exception then if sqlerrm like 'FAIL%' then raise; end if; end;
    begin
      insert into public.columns(name,kind) values(fixed.name,fixed.kind);
      raise exception 'FAIL duplicate fixed bucket accepted';
    exception when raise_exception then if sqlerrm like 'FAIL%' then raise; end if; end;
    begin
      insert into public.cards(title,column_id,project_id) values('Invalid creation',fixed.id,(select id from public.columns where name='SPARK'));
      raise exception 'FAIL direct creation in status bucket accepted';
    exception when raise_exception then if sqlerrm like 'FAIL%' then raise; end if; end;
  end loop;
  insert into public.columns(name,kind) values('QA editable project','project') returning id into project_id;
  update public.columns set name='QA updated project',color='mint',position=123 where id=project_id;
  begin
    update public.columns set kind='work' where id=project_id;
    raise exception 'FAIL project conversion accepted';
  exception when raise_exception then if sqlerrm like 'FAIL%' then raise; end if; end;
  begin
    update public.columns set name='Fertig' where id=project_id;
    raise exception 'FAIL reserved name accepted';
  exception when check_violation then null; end;
  delete from public.columns where id=project_id;
end $$;
update public.cards set reviewed_at=now() where id='20000000-0000-4000-8000-000000000001';
insert into public.comments(card_id,body) values('20000000-0000-4000-8000-000000000001','A comment notification');
do $$ begin
  if (select count(*) from public.notifications) <> 0 then raise exception 'Actor should not receive self notification'; end if;
end $$;
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000002',true);
do $$ begin
  if (select count(*) from public.notifications) <> 1 then raise exception 'Creator must receive one notification'; end if;
  if (select reviewed_by from public.cards where id='20000000-0000-4000-8000-000000000001') <> '10000000-0000-4000-8000-000000000001' then raise exception 'Reviewer missing'; end if;
end $$;
update public.notifications set seen_at=now();
do $$ begin if exists(select 1 from public.notifications where seen_at is null) then raise exception 'Mark seen failed'; end if; end $$;
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000003',true);
do $$ begin if exists(select 1 from public.cards) then raise exception 'Unprovisioned Auth user can access data'; end if; end $$;
reset role;
update public.profiles set active=false where id='10000000-0000-4000-8000-000000000002';
set local role authenticated;
select set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000002',true);
do $$ begin if exists(select 1 from public.cards) then raise exception 'Deactivated user can access data'; end if; end $$;
set local role anon;
do $$ begin
  begin perform count(*) from public.cards; raise exception 'FAIL anonymous access accepted';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'PASS: fixed bucket protection against admin edits/deletion/duplication/conversion, project-only creation, editable projects, shared visibility, immutable creator/project, completion, admin read receipts, notification delivery/isolation/seen, role escalation denial, inactive and unprovisioned denial, anonymous denial' as verification;
rollback;
