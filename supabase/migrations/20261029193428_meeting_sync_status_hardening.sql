-- Accurate dry-run receipts and defense in depth; no export contract changes.
create or replace function private.meeting_content_allowed_v1(p jsonb) returns boolean language plpgsql immutable set search_path='' as $f$
declare s text:=lower(normalize(p::text,NFKC)); i integer; j integer;
begin
 s:=translate(s,U&'\200B\200C\200D\FEFF','');
 for j in 1..3 loop
  if s like '%\%00%' escape '\' then return false; end if;
  for i in 1..127 loop s:=replace(s,'%'||lpad(to_hex(i),2,'0'),chr(i)); end loop;
  for i in 1..127 loop s:=replace(replace(s,'&#'||i::text||';',chr(i)),'&#x'||to_hex(i)||';',chr(i)); end loop;
 s:=replace(replace(replace(replace(s,'&hyphen;','-'),'&dash;','-'),'&sol;','/'),'&period;','.');
 s:=lower(regexp_replace(s,'<[^>]*>','','g'));
 end loop;
 return s !~ '(s[[:space:]_./-]*academy|(^|[^a-z])sak([^a-z]|$))';
end;$f$;
create or replace function private.sync_personal_meetings_v1(p_exports jsonb,p_dry_run boolean default true) returns jsonb language plpgsql security invoker set search_path='' as $f$
declare item jsonb; results jsonb:='[]';
begin
 if current_user<>'postgres' then raise exception using errcode='42501',message='MEETING_ACCESS_DENIED'; end if;
 if jsonb_typeof(p_exports)<>'array' or jsonb_array_length(p_exports) not between 1 and 10 then raise exception using errcode='P0001',message='MEETING_BATCH_INVALID'; end if;
 begin
  for item in select value from jsonb_array_elements(p_exports) loop results:=results||jsonb_build_array(private.apply_personal_meeting_v1(item,false)); end loop;
  if p_dry_run then raise exception using errcode='P0999',message='MEETING_DRY_RUN_ROLLBACK'; end if;
 exception when sqlstate 'P0999' then null;
 end;
 if p_dry_run then select coalesce(jsonb_agg(value||jsonb_build_object('status','validated','planned_status',value->>'status','dry_run',true,'persisted',false)),'[]'::jsonb) into results from jsonb_array_elements(results); end if;
 return jsonb_build_object('schema_version','salescrew.meeting.v1','dry_run',p_dry_run,'results',results);
end;$f$;
create index personal_meetings_workspace_fk on public.personal_meetings(workspace_id);
create index personal_meeting_sections_project_fk on public.personal_meeting_sections(project_id);
create index personal_meeting_sections_label_fk on public.personal_meeting_sections(primary_label_id);
create index personal_meeting_targets_project_fk on private.personal_meeting_label_targets(project_id);
