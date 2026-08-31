> Historical workspace note copied before the Trello migration on 2026-08-31. Earlier deployment addresses and test counts below describe the time of that note; the current app is https://get-simpl.vercel.app.

# Workspace confidentiality

- Admins see/manage every workspace. Employees' server-managed default_workspace_id is their home and authorization anchor; selecting another board never changes it.
- Full isolation: only home members and admins see that workspace, and its home members see no other workspace.
- Selective separation: one canonical blocked pair denies access in both directions. Other unrelated workspaces remain available. This is not transitive: allowing a third workspace never changes a user's home identity.
- Admin-only controls in Workspace bearbeiten: Offen, Gezielt trennen, Vollständig isolieren, with a clean selectable workspace list and an explicit two-way explanation.
- Workspaces, projects, cards, comments, attachments, Storage downloads/uploads, member profiles and labels are checked in database RLS. Labels become workspace-scoped, preserving existing card associations. Notifications require current card access at both creation and read time.
- Security uses live database profile/rule lookups, never client-selected IDs or editable JWT user metadata. Both direct Data API/RPC access and backend routes must obey it.
- Login requests authorized context before board data. Revalidate authorization before committing loaded data, clear stale UI on permission change/failure/account switch, and reset inaccessible selections.
- Replace business-row Realtime publication with per-user revision signals, so no hidden row content or deleted IDs are broadcast. Authorization signals clear the view; ordinary board signals refresh it. Five-second foreground revalidation is the fallback.
- Realistic limit: previously authorized downloads/copies cannot be recalled; new requests are denied as soon as committed rules apply. The local demo demonstrates behavior but is not a security boundary.
- Verify A/B symmetric blocking, isolated C, shared D without bridging, administrator override, old-token and forged-JWT-metadata attempts, direct reads/writes/RPCs, Storage paths, notifications, labels/profiles, realtime payloads and permission changes during open sessions.
