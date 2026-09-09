-- Admins can access every workspace, so members need their profiles in access lists.
alter policy member_profiles on public.profiles using (
  (select private.is_member()) and (
    id = (select auth.uid())
    or role = 'admin'
    or default_workspace_id = any((select private.accessible_workspace_ids())::uuid[])
  )
);
