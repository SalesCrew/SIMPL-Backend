-- All fixture data and operations are rolled back, including undo journals.
begin;
create temp table return_location_qa as select gen_random_uuid() as workspace,
  gen_random_uuid() as other_workspace, gen_random_uuid() as actor, gen_random_uuid() as outsider,
  gen_random_uuid() as project, gen_random_uuid() as other_project,
  gen_random_uuid() as work, gen_random_uuid() as done,
  gen_random_uuid() as a, gen_random_uuid() as b, gen_random_uuid() as c, gen_random_uuid() as d;
grant select on return_location_qa to authenticated;
insert into public.workspaces(id,name,isolated)
select workspace,'Return QA ' || workspace::text,true from return_location_qa
union all select other_workspace,'Return QA ' || other_workspace::text,true from return_location_qa;
update return_location_qa q set work=(select id from public.columns where workspace_id=q.workspace and kind='work'),
  done=(select id from public.columns where workspace_id=q.workspace and kind='done');
insert into auth.users(id,email)
select actor,actor::text || '@example.invalid' from return_location_qa
union all select outsider,outsider::text || '@example.invalid' from return_location_qa;
insert into public.profiles(id,email,name,role,default_workspace_id,active)
select actor,actor::text || '@example.invalid','Return QA owner','mitarbeiter',workspace,true from return_location_qa
union all select outsider,outsider::text || '@example.invalid','Return QA outsider','mitarbeiter',other_workspace,true from return_location_qa;
insert into public.columns(id,workspace_id,name,kind,color,position)
select project,workspace,'Project A','project','sage'::public.workspace_color,0 from return_location_qa
union all select other_project,workspace,'Project B','project','blue',1 from return_location_qa;
select set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true) from return_location_qa;
set local role authenticated;
do $$
declare q record; card_id uuid; saved public.cards; actual uuid[]; session_id uuid := gen_random_uuid();
begin
  select * into q from return_location_qa;
  foreach card_id in array array[q.a,q.b,q.c,q.d] loop
    insert into public.cards(id,title,column_id,project_id)
      values(card_id,'Return location QA',q.project,q.project);
  end loop;
  foreach card_id in array array[q.a,q.b,q.d] loop
    perform public.set_card_completed(card_id,true);
    select * into saved from public.cards where id=card_id;
    if saved.return_column_id <> q.project then raise exception 'FAIL missing origin'; end if;
    perform public.set_card_completed(card_id,true);
    if (select edit_revision from public.cards where id=card_id) <> saved.edit_revision then
      raise exception 'FAIL repeated completion changed metadata';
    end if;
    perform public.set_card_completed(card_id,false);
    select array_agg(id order by position,id) into actual from public.cards where column_id=q.project;
    if actual <> array[q.a,q.b,q.c,q.d] then raise exception 'FAIL first/middle/last return: %',actual; end if;
  end loop;
  perform public.move_card(q.b,q.work,null);
  perform public.move_card(q.b,q.work,null);
  perform public.set_card_completed(q.b,true);
  perform public.move_card(q.b,q.done,null);
  perform public.move_card(q.d,q.project,q.a); -- Rebalances the project while B is away.
  perform public.set_card_completed(q.b,false);
  select array_agg(id order by position,id) into actual from public.cards where column_id=q.project;
  if actual <> array[q.d,q.a,q.b,q.c] then raise exception 'FAIL In Arbeit/rebalance return: %',actual; end if;
  foreach card_id in array array[q.a,q.b,q.c] loop
    perform public.move_card(card_id,q.other_project,null);
  end loop;
  perform public.move_card(q.b,q.work,null);
  perform public.set_card_completed(q.b,true);
  -- Direct client updates cannot forge the persisted origin or neighbors.
  update public.cards set return_column_id=q.project,return_before_id=q.d,return_after_id=null,return_index=99 where id=q.b;
  if (select return_column_id from public.cards where id=q.b) <> q.other_project then
    raise exception 'FAIL client overwrote origin';
  end if;
  perform public.card_edit_session(session_id,'begin',q.b,null);
  perform public.card_edit_session(session_id,'mutate',q.b,jsonb_build_object('type','card.complete','id',q.b,'completed',false));
  perform public.card_edit_session(session_id,'close',q.b,null);
  perform public.card_edit_session(session_id,'undo',q.b,null);
  select * into saved from public.cards where id=q.b;
  if saved.column_id <> q.done or saved.return_column_id <> q.other_project or saved.return_before_id <> q.c then
    raise exception 'FAIL undo lost return location';
  end if;
  perform public.set_card_completed(q.b,false);
  select array_agg(id order by position,id) into actual from public.cards where column_id=q.other_project;
  if actual <> array[q.a,q.b,q.c] then raise exception 'FAIL latest project/undo return: %',actual; end if;
  if (select project_id from public.cards where id=q.b) <> q.project then raise exception 'FAIL creation project changed'; end if;
  perform public.set_card_completed(q.b,true);
  delete from public.cards where id=q.c;
  perform public.set_card_completed(q.b,false);
  select array_agg(id order by position,id) into actual from public.cards where column_id=q.other_project;
  if actual <> array[q.a,q.b] then raise exception 'FAIL deleted next neighbor fallback'; end if;
  perform public.set_card_completed(q.b,true);
  delete from public.cards where id=q.a;
  perform public.move_card(q.d,q.other_project,null);
  perform public.set_card_completed(q.b,false);
  select array_agg(id order by position,id) into actual from public.cards where column_id=q.other_project;
  if actual <> array[q.d,q.b] then raise exception 'FAIL missing neighbors/index fallback'; end if;
  perform public.set_card_completed(q.b,true);
end;
$$;
select set_config('request.jwt.claims',jsonb_build_object('sub',outsider,'role','authenticated')::text,true) from return_location_qa;
do $$ begin
  if exists(select 1 from public.cards where id=(select b from return_location_qa)) then
    raise exception 'FAIL isolated member sees card/origin';
  end if;
  begin
    perform public.set_card_completed((select b from return_location_qa),false);
    raise exception 'FAIL isolated member reopened card';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
end $$;
select 'PASS: exact project slots; work/done transitions; idempotency; rebalancing; last project; protected metadata; undo; missing neighbors; NDA isolation. All fixtures rolled back.' as result;
rollback;
