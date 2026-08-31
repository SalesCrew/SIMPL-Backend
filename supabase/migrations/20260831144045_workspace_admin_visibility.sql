-- Newly inserted workspaces are not yet in the statement's cached access-ID set.
-- Admin override must also cover INSERT ... ON CONFLICT and nested workspace seeding.
alter policy member_workspaces on public.workspaces using (
  (select private.is_admin()) or id = any((select private.accessible_workspace_ids())::uuid[])
);
alter policy member_columns on public.columns using (
  (select private.is_admin()) or workspace_id = any((select private.accessible_workspace_ids())::uuid[])
);
alter policy member_labels_select on public.labels using (
  (select private.is_admin()) or workspace_id = any((select private.accessible_workspace_ids())::uuid[])
);
alter policy member_labels_insert on public.labels with check (
  (select private.is_admin()) or workspace_id = any((select private.accessible_workspace_ids())::uuid[])
);
alter policy member_labels_update on public.labels using (
  (select private.is_admin()) or workspace_id = any((select private.accessible_workspace_ids())::uuid[])
) with check (
  (select private.is_admin()) or workspace_id = any((select private.accessible_workspace_ids())::uuid[])
);
