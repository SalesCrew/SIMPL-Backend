-- Reverse lookups are used when workspaces or projects are removed and when
-- support tooling inspects preferences by scope.
create index email_notification_workspace_preferences_workspace
  on public.email_notification_workspace_preferences(workspace_id,user_id);
create index email_notification_project_preferences_project
  on public.email_notification_project_preferences(project_id,user_id);
