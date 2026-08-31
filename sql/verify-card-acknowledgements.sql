-- Real authenticated-role checks with disposable fixtures. Always rolled back.
begin;
do $$
declare member_id uuid := gen_random_uuid(); admin_id uuid := gen_random_uuid();
  outsider_id uuid := gen_random_uuid(); unprovisioned_id uuid := gen_random_uuid();
  home_id uuid := gen_random_uuid(); hidden_id uuid := gen_random_uuid();
  card_id uuid := gen_random_uuid(); hidden_card_id uuid := gen_random_uuid(); project uuid;
begin
  insert into public.workspaces(id,name,color,isolated) values
    (home_id,'Acknowledgement QA home','sage',true),(hidden_id,'Acknowledgement QA hidden','sage',true);
  insert into auth.users(id,email) values
    (member_id,member_id||'@example.invalid'),(admin_id,admin_id||'@example.invalid'),
    (outsider_id,outsider_id||'@example.invalid'),(unprovisioned_id,unprovisioned_id||'@example.invalid');
  insert into public.profiles(id,email,name,role,default_workspace_id) values
    (member_id,member_id||'@example.invalid','Ack member','mitarbeiter',home_id),
    (admin_id,admin_id||'@example.invalid','Ack admin','admin',home_id),
    (outsider_id,outsider_id||'@example.invalid','Ack outsider','mitarbeiter',hidden_id);
  perform set_config('request.jwt.claim.sub',member_id::text,true);
  select id into project from public.columns where workspace_id=home_id and kind='project';
  insert into public.cards(id,title,column_id,project_id) values(card_id,'Acknowledgement fixture',project,project);
  perform set_config('request.jwt.claim.sub',outsider_id::text,true);
  select id into project from public.columns where workspace_id=hidden_id and kind='project';
  insert into public.cards(id,title,column_id,project_id) values(hidden_card_id,'Hidden acknowledgement fixture',project,project);
  perform set_config('ack_test.member',member_id::text,true);
  perform set_config('ack_test.admin',admin_id::text,true);
  perform set_config('ack_test.unprovisioned',unprovisioned_id::text,true);
  perform set_config('ack_test.home',home_id::text,true);
  perform set_config('ack_test.hidden',hidden_id::text,true);
  perform set_config('ack_test.card',card_id::text,true);
  perform set_config('ack_test.hidden_card',hidden_card_id::text,true);
end $$;
set local role authenticated;
do $$
declare c uuid := current_setting('ack_test.card')::uuid; hidden uuid := current_setting('ack_test.hidden_card')::uuid;
  member_id uuid := current_setting('ack_test.member')::uuid; admin_id uuid := current_setting('ack_test.admin')::uuid;
  sid uuid := gen_random_uuid(); n integer; marked_at timestamptz;
begin
  if current_user <> 'authenticated' then raise exception 'Must test actual RLS role'; end if;
  perform set_config('request.jwt.claim.sub',member_id::text,true);
  -- Board/direct update: creator and timestamp cannot be forged.
  update public.cards set reviewed_at='2000-01-01',reviewed_by=admin_id where id=c;
  if not exists(select 1 from public.cards where id=c and reviewed_by=member_id and reviewed_at=now()) then
    raise exception 'Member acknowledgement or server audit attribution failed';
  end if;
  update public.cards set reviewed_at=null,reviewed_by=admin_id where id=c;
  if not exists(select 1 from public.cards where id=c and reviewed_at is null and reviewed_by is null) then
    raise exception 'Member could not clear acknowledgement';
  end if;
  -- Card dialog/session path, including input validation and undo.
  perform public.card_edit_session(sid,'begin',c);
  begin
    perform public.card_edit_session(sid,'mutate',c,jsonb_build_object('type','card.review','id',c));
    raise exception 'Missing acknowledgement status accepted';
  exception when invalid_parameter_value then null; end;
  perform public.card_edit_session(sid,'mutate',c,jsonb_build_object('type','card.review','id',c,'reviewed',true));
  if not exists(select 1 from public.cards where id=c and reviewed_by=member_id and reviewed_at is not null) then
    raise exception 'Member session acknowledgement failed';
  end if;
  perform public.card_edit_session(sid,'close',c);
  perform public.card_edit_session(sid,'undo',c);
  if not exists(select 1 from public.cards where id=c and reviewed_at is null and reviewed_by is null) then
    raise exception 'Member acknowledgement undo failed';
  end if;
  perform set_config('request.jwt.claim.sub',admin_id::text,true);
  sid := gen_random_uuid();
  perform public.card_edit_session(sid,'begin',c);
  perform public.card_edit_session(sid,'mutate',c,jsonb_build_object('type','card.review','id',c,'reviewed',true));
  perform public.card_edit_session(sid,'discard',c);
  select reviewed_at into marked_at from public.cards where id=c;
  if not exists(select 1 from public.cards where id=c and reviewed_by=admin_id and reviewed_at is not null) then
    raise exception 'Admin acknowledgement failed';
  end if;
  -- A member can clear an admin's mark, and undo restores its original author/time.
  perform set_config('request.jwt.claim.sub',member_id::text,true);
  sid := gen_random_uuid();
  perform public.card_edit_session(sid,'begin',c);
  perform public.card_edit_session(sid,'mutate',c,jsonb_build_object('type','card.review','id',c,'reviewed',false));
  if not exists(select 1 from public.cards where id=c and reviewed_at is null and reviewed_by is null) then
    raise exception 'Shared acknowledgement clear failed';
  end if;
  perform public.card_edit_session(sid,'close',c);
  perform public.card_edit_session(sid,'undo',c);
  if not exists(select 1 from public.cards where id=c and reviewed_at=marked_at and reviewed_by=admin_id) then
    raise exception 'Undo did not preserve original acknowledgement';
  end if;
  update public.cards set reviewed_at=now() where id=hidden;
  get diagnostics n=row_count;
  if n<>0 then raise exception 'Isolated workspace update escaped RLS'; end if;
  begin
    perform public.card_edit_session(gen_random_uuid(),'begin',hidden);
    raise exception 'Isolated workspace session escaped access checks';
  exception when insufficient_privilege then null; end;
  sid := gen_random_uuid();
  perform public.card_edit_session(sid,'begin',c);
  perform set_config('ack_test.session',sid::text,true);
end $$;
reset role;
-- Revoke a member with an already-open edit session; also test explicit pair blocks.
update public.profiles set active=false where id=current_setting('ack_test.member')::uuid;
update public.workspaces set isolated=false where id in (current_setting('ack_test.home')::uuid,current_setting('ack_test.hidden')::uuid);
insert into public.workspace_blocks(workspace_a,workspace_b) values
  (least(current_setting('ack_test.home')::uuid,current_setting('ack_test.hidden')::uuid),
   greatest(current_setting('ack_test.home')::uuid,current_setting('ack_test.hidden')::uuid));
set local role authenticated;
do $$
declare n integer; c uuid := current_setting('ack_test.card')::uuid;
begin
  update public.cards set reviewed_at=null where id=c;
  get diagnostics n=row_count;
  if n<>0 then raise exception 'Inactive member update accepted'; end if;
  begin
    perform public.card_edit_session(current_setting('ack_test.session')::uuid,'mutate',c,
      jsonb_build_object('type','card.review','id',c,'reviewed',false));
    raise exception 'Revoked session acknowledgement accepted';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
update public.profiles set active=true where id=current_setting('ack_test.member')::uuid;
set local role authenticated;
do $$
declare n integer; hidden uuid := current_setting('ack_test.hidden_card')::uuid;
begin
  update public.cards set reviewed_at=now() where id=hidden;
  get diagnostics n=row_count;
  if n<>0 then raise exception 'Blocked workspace update accepted'; end if;
  begin
    perform public.card_edit_session(gen_random_uuid(),'begin',hidden);
    raise exception 'Blocked workspace session accepted';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',current_setting('ack_test.unprovisioned'),true);
  update public.cards set reviewed_at=now() where id=current_setting('ack_test.card')::uuid;
  get diagnostics n=row_count;
  if n<>0 then raise exception 'Unprovisioned user update accepted'; end if;
  begin
    perform public.card_edit_session(gen_random_uuid(),'begin',current_setting('ack_test.card')::uuid);
    raise exception 'Unprovisioned user session accepted';
  exception when insufficient_privilege then null; end;
end $$;
set local role anon;
do $$ begin
  begin
    update public.cards set reviewed_at=now() where id=current_setting('ack_test.card')::uuid;
    raise exception 'Anonymous update accepted';
  exception when insufficient_privilege then null; end;
  begin
    perform public.card_edit_session(gen_random_uuid(),'begin',current_setting('ack_test.card')::uuid);
    raise exception 'Anonymous session accepted';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'PASS: both roles, on/off, actor/time integrity, session undo, isolated/blocked workspaces, revoked/unprovisioned/anonymous denial' as verification;
rollback;
