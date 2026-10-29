-- Cover complete owner/workspace foreign keys, including parent deletion checks.
create index personal_meeting_aliases_owner_reference on public.personal_meeting_aliases(meeting_id, owner_id, workspace_id);
create index personal_meeting_sections_owner_reference on public.personal_meeting_sections(meeting_id, owner_id, workspace_id);
create index personal_meeting_revisions_owner_reference on public.personal_meeting_revisions(meeting_id, owner_id, workspace_id);
create index personal_meeting_links_owner_reference on public.personal_meeting_links(meeting_id, owner_id, workspace_id);
