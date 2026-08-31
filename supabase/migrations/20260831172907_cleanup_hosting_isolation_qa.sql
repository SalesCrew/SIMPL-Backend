-- Only the four empty workspaces created by this hosting verification run.
-- No-op on a new database. User workspace IDs are never assumed.
do $$
declare targets uuid[];
begin
  perform 1 from public.workspaces where name in (
    'Isolation QA fc523010 A','Isolation QA fc523010 B',
    'Isolation QA fc523010 C','Isolation QA fc523010 Shared'
  ) for update;
  select array_agg(id) into targets from public.workspaces where name in (
    'Isolation QA fc523010 A','Isolation QA fc523010 B',
    'Isolation QA fc523010 C','Isolation QA fc523010 Shared'
  );
  if targets is null then return; end if;
  if exists(select 1 from public.cards where workspace_id = any(targets))
    or exists(select 1 from public.profiles where default_workspace_id = any(targets))
  then raise exception 'Refusing cleanup: verification workspaces are not empty'; end if;
  delete from public.workspace_blocks where workspace_a = any(targets) or workspace_b = any(targets);
  delete from public.labels where workspace_id = any(targets);
  -- This transaction locks the table and restores the validator before commit.
  alter table public.columns disable trigger validate_column;
  delete from public.columns where workspace_id = any(targets);
  alter table public.columns enable trigger validate_column;
  delete from public.workspaces where id = any(targets);
end;
$$;
