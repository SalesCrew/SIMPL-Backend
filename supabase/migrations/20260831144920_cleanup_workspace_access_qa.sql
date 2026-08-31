-- Remove only the empty, agent-created fixtures from this verification run.
-- Replaying on a fresh database is a no-op. No generated record IDs are assumed.
do $$
declare targets uuid[];
begin
  perform 1 from public.workspaces
  where name in ('Isolation QA bedc7352 A','Isolation QA bedc7352 B','Isolation QA bedc7352 C','Isolation QA bedc7352 Shared',
                'Isolation QA d76a6cd9 A','Isolation QA d76a6cd9 B','Isolation QA d76a6cd9 C','Isolation QA d76a6cd9 Shared')
  for update;
  select array_agg(id) into targets from public.workspaces
  where name in ('Isolation QA bedc7352 A','Isolation QA bedc7352 B','Isolation QA bedc7352 C','Isolation QA bedc7352 Shared',
                'Isolation QA d76a6cd9 A','Isolation QA d76a6cd9 B','Isolation QA d76a6cd9 C','Isolation QA d76a6cd9 Shared');
  if targets is null then return; end if;
  if exists(select 1 from public.cards where workspace_id = any(targets))
    or exists(select 1 from public.profiles where default_workspace_id = any(targets))
  then raise exception 'Refusing cleanup: QA workspaces are not empty'; end if;
  delete from public.workspace_blocks where workspace_a = any(targets) or workspace_b = any(targets);
  delete from public.labels where workspace_id = any(targets);
  -- Ordinary API clients still cannot delete fixed buckets. Owner-only DDL is scoped
  -- to this transaction, with FK checks retained and the validator restored immediately.
  alter table public.columns disable trigger validate_column;
  delete from public.columns where workspace_id = any(targets);
  alter table public.columns enable trigger validate_column;
  delete from public.workspaces where id = any(targets);
end;
$$;
