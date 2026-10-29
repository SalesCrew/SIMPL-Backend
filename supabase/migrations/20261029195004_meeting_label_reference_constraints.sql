-- Existing label routing is also a relational invariant, including supplementary Coke tags.
alter table private.personal_meeting_label_targets add constraint personal_meeting_label_target_pair unique(primary_label_id,project_id);
alter table public.personal_meeting_sections add constraint personal_meeting_label_project_pair foreign key(primary_label_id,project_id) references private.personal_meeting_label_targets(primary_label_id,project_id);
alter table public.personal_meeting_sections add constraint personal_meeting_section_scope check ((primary_label_id is null and project_id is null and cardinality(label_ids)=0) or (primary_label_id is not null and project_id is not null and primary_label_id=any(label_ids)));
alter table public.personal_meeting_sections add constraint personal_meeting_coke_subcategory_scope check (not(label_ids && array['780f22ad-988c-41a1-8463-b84fe82969d8','130989d7-dcfb-4c55-b673-3a10a14f95dd']::uuid[]) or coalesce(primary_label_id='b8f71d57-9822-5aba-a977-d3dc7ff95655'::uuid,false));
create index personal_meeting_section_label_project on public.personal_meeting_sections(primary_label_id,project_id);
create function private.guard_personal_meeting_subcategory_v1() returns trigger language plpgsql security invoker set search_path='' as $f$
begin
 if new.label_ids && array['780f22ad-988c-41a1-8463-b84fe82969d8','130989d7-dcfb-4c55-b673-3a10a14f95dd']::uuid[] and new.primary_label_id is distinct from 'b8f71d57-9822-5aba-a977-d3dc7ff95655'::uuid then raise exception using errcode='P0001',message='MEETING_LABEL_SCOPE_INVALID'; end if;
 return new;
end;$f$;
revoke all on function private.guard_personal_meeting_subcategory_v1() from public,anon,authenticated,service_role;
create trigger guard_personal_meeting_subcategory before insert or update on public.personal_meeting_sections for each row execute function private.guard_personal_meeting_subcategory_v1();

-- Optional existing task links follow actual label membership as well.
create or replace function private.apply_personal_meeting_v1(p_export jsonb,p_dry_run boolean default true) returns jsonb language plpgsql security invoker set search_path='' as $f$
declare c json; m public.personal_meetings%rowtype; item jsonb; ref text; target uuid; mid uuid; own uuid:='e68b62cd-06b3-4300-8a16-dc04e20ed75d'; ws uuid:='2bb0db3c-9ec4-4066-8f58-0a7712fb6325'; day date; start_time timestamptz; end_time timestamptz; next_rev integer; affected uuid[]:=array[]::uuid[]; changed_labels uuid[]:=array[]::uuid[]; previous_export jsonb;
begin
 if (select count(*) from public.profiles where id=own and lower(email)='kilian.sternath@salescrew.at' and active)<>1 or not private.user_can_access_workspace(own,ws) then raise exception using errcode='42501',message='MEETING_OWNER_UNAVAILABLE'; end if;
 select schema into c from private.personal_meeting_contracts where version='salescrew.meeting.v1';
 if octet_length(convert_to(private.meeting_canonical_json(p_export),'UTF8'))>1048576 then raise exception using errcode='P0001',message='MEETING_PAYLOAD_TOO_LARGE'; end if;
 if not coalesce(extensions.jsonb_matches_schema(c,p_export),false) then raise exception using errcode='P0001',message='MEETING_SCHEMA_INVALID'; end if;
 if not private.meeting_content_allowed_v1(p_export) then raise exception using errcode='P0001',message='MEETING_CONTENT_EXCLUDED'; end if;
 if private.meeting_payload_hash_v1(p_export)<>p_export->>'content_hash' then raise exception using errcode='P0001',message='MEETING_HASH_MISMATCH'; end if;
 mid:=(p_export->>'meeting_id')::uuid;day:=(p_export#>>'{occurred,day}')::date;start_time:=(p_export#>>'{occurred,starts_at}')::timestamptz;end_time:=(p_export#>>'{occurred,ends_at}')::timestamptz;
 if day>(now() at time zone 'Europe/Vienna')::date or (start_time is not null and (start_time at time zone 'Europe/Vienna')::date is distinct from day) or (end_time is not null and (start_time is null or end_time<start_time)) or ((p_export#>>'{occurred,precision}')='unknown' and (day is not null or start_time is not null or end_time is not null)) or ((p_export#>>'{occurred,precision}')='day' and (day is null or start_time is not null or end_time is not null)) or ((p_export#>>'{occurred,precision}')='minute' and (day is null or start_time is null)) then raise exception using errcode='P0001',message='MEETING_DATE_INVALID'; end if;
 if (p_export->>'revision')::integer<>(p_export->>'base_revision')::integer+1 then raise exception using errcode='P0001',message='MEETING_REVISION_INVALID'; end if;
 perform pg_advisory_xact_lock(hashtextextended(own::text||ws::text||'meeting-sync',0));
 select * into m from public.personal_meetings where id=mid for update;
 if found and m.content_hash=p_export->>'content_hash' then return jsonb_build_object('status','unchanged','meeting_id',mid,'revision',m.revision,'content_hash',m.content_hash,'dry_run',p_dry_run); end if;
 if coalesce(m.revision,0)<>(p_export->>'base_revision')::integer then raise exception using errcode='P0001',message='MEETING_REVISION_CONFLICT'; end if;
 if m.id is not null and m.kind<>p_export->>'kind' then raise exception using errcode='P0001',message='MEETING_IDENTITY_CONFLICT'; end if;
 if exists(select 1 from public.personal_meeting_aliases where owner_id=own and workspace_id=ws and external_id in (select jsonb_array_elements_text(p_export->'external_ids')) and meeting_id<>mid) then raise exception using errcode='P0001',message='MEETING_IDENTITY_CONFLICT'; end if;
 if (select count(distinct s->>'section_id') from jsonb_array_elements(p_export->'sections') s)<>jsonb_array_length(p_export->'sections') or exists(select 1 from public.personal_meeting_sections s where s.meeting_id=mid and s.section_id not in (select (v->>'section_id')::uuid from jsonb_array_elements(p_export->'sections') v)) then raise exception using errcode='P0001',message='MEETING_SECTION_CONFLICT'; end if;
 for item in select value from jsonb_array_elements(p_export->'sections') loop
  if exists(select 1 from public.personal_meeting_sections where (section_id=(item->>'section_id')::uuid or note_ref=item->>'note_ref') and meeting_id<>mid) then raise exception using errcode='P0001',message='MEETING_IDENTITY_CONFLICT'; end if;
  if p_export->>'kind'='project_meeting' and not exists(select 1 from public.columns where id=(item->>'project_id')::uuid and workspace_id=ws and kind='project') then raise exception using errcode='P0001',message='MEETING_PROJECT_INVALID'; end if;
  if p_export->>'kind'='project_meeting' and not exists(select 1 from private.personal_meeting_label_targets t join public.labels l on l.id=t.primary_label_id join public.columns c on c.id=t.project_id where t.primary_label_id=(item->>'primary_label_id')::uuid and t.project_id=(item->>'project_id')::uuid and l.workspace_id=ws and c.workspace_id=ws and c.kind='project' and private.meeting_content_allowed_v1(to_jsonb(l.name||' '||c.name)) and (item->'label_ids') @> jsonb_build_array(item->>'primary_label_id')) then raise exception using errcode='P0001',message='MEETING_PRIMARY_LABEL_INVALID'; end if;
  if exists(select 1 from jsonb_array_elements_text(item->'label_ids') x(id) join private.personal_meeting_label_targets t on t.primary_label_id=x.id::uuid where t.primary_label_id is distinct from (item->>'primary_label_id')::uuid) then raise exception using errcode='P0001',message='MEETING_LABEL_SCOPE_INVALID'; end if;
  if exists(select 1 from jsonb_array_elements_text(item->'label_ids') l(id) where not exists(select 1 from public.labels where id=l.id::uuid and workspace_id=ws)) then raise exception using errcode='P0001',message='MEETING_LABEL_INVALID'; end if;
  if exists(select 1 from jsonb_array_elements(item->'actions') a where a->>'card_id' is not null and not exists(select 1 from public.cards where id=(a->>'card_id')::uuid and workspace_id=ws and deleted_at is null and (item->>'primary_label_id' is null or (item->>'primary_label_id')::uuid=any(label_ids)))) then raise exception using errcode='P0001',message='MEETING_CARD_INVALID'; end if;
  if (select count(distinct s->>'id') from jsonb_array_elements(item->'sources') s)<>jsonb_array_length(item->'sources') then raise exception using errcode='P0001',message='MEETING_SOURCE_INVALID'; end if;
  for ref in select jsonb_array_elements_text(q.value) from jsonb_path_query(item,'$.**.source_ids') q(value) loop
   if not exists(select 1 from jsonb_array_elements(item->'sources') source where source->>'id'=ref) then raise exception using errcode='P0001',message='MEETING_SOURCE_INVALID'; end if;
  end loop;
  for target in select distinct x::uuid from (select item#>>'{comparison,previous_meeting_id}' x union all select v->>'comparison_meeting_id' from jsonb_array_elements(item->'changes') v) refs where x is not null loop
   if target=mid or not exists(select 1 from public.personal_meetings pm join public.personal_meeting_sections ps on ps.meeting_id=pm.id where pm.id=target and pm.owner_id=own and pm.workspace_id=ws and pm.kind=p_export->>'kind' and ps.primary_label_id is not distinct from (item->>'primary_label_id')::uuid and (day is null or pm.meeting_date<=day)) then raise exception using errcode='P0001',message='MEETING_COMPARISON_INVALID'; end if;
  end loop;
 end loop;
 select export into previous_export from public.personal_meeting_revisions where meeting_id=mid and revision=m.revision;
 select array_agg((current_section->>'primary_label_id')::uuid) into changed_labels from jsonb_array_elements(p_export->'sections') current_section where m.meeting_date is distinct from day or not exists(select 1 from jsonb_array_elements(coalesce(previous_export->'sections','[]'::jsonb)) old_section where old_section=current_section);
 next_rev:=coalesce(m.revision,0)+1;
 if p_dry_run then return jsonb_build_object('status','validated','meeting_id',mid,'revision',next_rev,'content_hash',p_export->>'content_hash','dry_run',true); end if;
 insert into public.personal_meetings(id,owner_id,workspace_id,kind,title,meeting_date,starts_at,ends_at,date_precision,date_status,timezone,revision,content_hash,note_created_on,note_updated_at,metadata)
 values(mid,own,ws,p_export->>'kind',p_export->>'title',day,start_time,end_time,p_export#>>'{occurred,precision}',p_export#>>'{occurred,status}','Europe/Vienna',next_rev,p_export->>'content_hash',(p_export->>'note_created_on')::date,(p_export->>'note_updated_at')::timestamptz,p_export-array['sections','base_revision','revision','content_hash','exported_at'])
 on conflict(id) do update set title=excluded.title,meeting_date=excluded.meeting_date,starts_at=excluded.starts_at,ends_at=excluded.ends_at,date_precision=excluded.date_precision,date_status=excluded.date_status,revision=excluded.revision,content_hash=excluded.content_hash,note_updated_at=excluded.note_updated_at,metadata=excluded.metadata,synced_at=now();
 for item in select value from jsonb_array_elements(p_export->'sections') loop
  insert into public.personal_meeting_sections(section_id,meeting_id,owner_id,workspace_id,project_id,primary_label_id,label_ids,note_ref,presentation,comparison,changes,actions,followups,sources,markdown,content_scope)
  values((item->>'section_id')::uuid,mid,own,ws,(item->>'project_id')::uuid,(item->>'primary_label_id')::uuid,array(select jsonb_array_elements_text(item->'label_ids'))::uuid[],item->>'note_ref',item->'presentation',item->'comparison',item->'changes',item->'actions',item->'followups',item->'sources',item->>'markdown',item->>'content_scope')
  on conflict(section_id) do update set project_id=excluded.project_id,primary_label_id=excluded.primary_label_id,label_ids=excluded.label_ids,note_ref=excluded.note_ref,presentation=excluded.presentation,comparison=excluded.comparison,changes=excluded.changes,actions=excluded.actions,followups=excluded.followups,sources=excluded.sources,markdown=excluded.markdown,content_scope=excluded.content_scope,comparison_review_required=case when personal_meeting_sections.comparison_review_required and personal_meeting_sections.comparison=excluded.comparison then true else false end;
  delete from public.personal_meeting_links where meeting_id=mid and section_id=(item->>'section_id')::uuid;
  insert into public.personal_meeting_links(meeting_id,section_id,target_meeting_id,owner_id,workspace_id)
   select mid,(item->>'section_id')::uuid,x::uuid,own,ws from (select item#>>'{comparison,previous_meeting_id}' x union select v->>'comparison_meeting_id' from jsonb_array_elements(item->'changes') v) refs where x is not null;
 end loop;
 insert into public.personal_meeting_aliases select own,ws,value,mid from jsonb_array_elements_text(p_export->'external_ids') on conflict do nothing;
 insert into public.personal_meeting_revisions values(mid,own,ws,next_rev,p_export->>'content_hash',p_export->>'revision_reason',p_export,now());
 if m.id is null or m.content_hash is distinct from p_export->>'content_hash' then
  with changed as (update public.personal_meeting_sections ps set comparison_review_required=true from public.personal_meetings pm where ps.meeting_id=pm.id and pm.id<>mid and pm.meeting_date>least(m.meeting_date,day) and pm.kind=p_export->>'kind' and exists(select 1 from unnest(changed_labels) label_id where label_id is not distinct from ps.primary_label_id) returning ps.meeting_id) select coalesce(array_agg(distinct meeting_id),array[]::uuid[]) into affected from changed;
 end if;
 update public.access_revisions set board_version=board_version+1 where id=own;
 return jsonb_build_object('status',case when m.id is null then 'created' else 'updated' end,'meeting_id',mid,'revision',next_rev,'content_hash',p_export->>'content_hash','dry_run',false,'comparison_review_meeting_ids',affected);
exception when invalid_datetime_format or datetime_field_overflow then raise exception using errcode='P0001',message='MEETING_DATE_INVALID';
end;$f$;