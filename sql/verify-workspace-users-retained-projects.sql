-- All verification writes roll back, including board revisions/notifications.
begin;
set local lock_timeout='5s';
do $$
declare workspace uuid; project uuid:=gen_random_uuid(); member uuid; before_profile jsonb;
begin
  select id into strict workspace from public.workspaces where name='Development';
  select id,to_jsonb(p) into member,before_profile from public.profiles p
    where default_workspace_id=workspace order by id limit 1;
  if member is null then raise exception 'Missing workspace fixture identity'; end if;
  insert into public.columns(id,workspace_id,name,color,kind,position)
    values(project,workspace,'Rollback-only project retention check','sage','project',9999);
  update public.profiles set default_column_id=project where id=member;
  if (select default_column_id is not null from public.profiles where id=member) then
    raise exception 'A legacy project binding survived';
  end if;
  if before_profile is distinct from (select to_jsonb(p) from public.profiles p where id=member) then
    raise exception 'Workspace-bound profile identity changed';
  end if;
  update public.columns set archived_at=clock_timestamp() where id=project;
  if not exists(select 1 from public.columns where id=project and archived_at is not null
    and name='Rollback-only project retention check' and workspace_id=workspace) then
    raise exception 'Removed project metadata was lost';
  end if;
  begin
    delete from public.columns where id=project;
    raise exception 'Unexpected permanent deletion';
  exception when raise_exception then
    if sqlerrm<>'Entfernte Projekte bleiben für die Historie erhalten.' then raise; end if;
  end;
  begin
    insert into public.cards(workspace_id,column_id,project_id,title)
      values(workspace,project,project,'Must not enter a removed project');
    raise exception 'Unexpected insert into a removed project';
  exception when raise_exception then
    if sqlerrm<>'Dieses Projekt wurde aus dem aktiven Board entfernt. Bitte ein aktives Projekt wählen.' then raise; end if;
  end;
  begin
    perform public.archive_project(project);
    raise exception 'Unauthenticated project RPC accepted';
  exception when insufficient_privilege then null;
  end;
end;
$$;
select 'PASS: workspace normalization, retained project identity, hard-delete protection, active-target guard and RPC authentication' as result;
rollback;
