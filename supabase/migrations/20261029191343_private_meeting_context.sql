
-- Additive private meeting context. No card, project, label or notification mutation.
create extension if not exists pg_jsonschema with schema extensions;
create table private.personal_meeting_contracts(version text primary key, schema json not null, schema_hash text not null);
alter table private.personal_meeting_contracts enable row level security;
revoke all on private.personal_meeting_contracts from public, anon, authenticated, service_role;
insert into private.personal_meeting_contracts values ('salescrew.meeting.v1', $schema${"$id":"urn:salescrew:simpl:meeting-export:v1","$schema":"http://json-schema.org/draft-07/schema#","additionalProperties":false,"allOf":[{"else":{"properties":{"sections":{"items":{"properties":{"content_scope":{"enum":["single_project","allowed_excerpt"]},"primary_label_id":{"pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$","type":"string"},"project_id":{"pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$","type":"string"}}}}}},"if":{"properties":{"kind":{"const":"jour_fixe"}}},"then":{"properties":{"sections":{"items":{"properties":{"content_scope":{"const":"jour_fixe"},"label_ids":{"maxItems":0},"primary_label_id":{"type":"null"},"project_id":{"type":"null"}}},"maxItems":1}}}}],"description":"Private owner-scoped meeting export. Full relational, chronology, content-scope and authorization checks additionally run in the receiver. Maximum canonical UTF-8 payload 1048576 bytes. No secrets. content_hash is SHA-256 of recursively key-sorted compact UTF-8 JSON, excluding content_hash, exported_at, revision and base_revision. Arrays retain order. Filtering and routing use the existing primary_label_id (SPARK, ROVER, Compass, OBI, Nespresso, SIMPL). project_id is an internal integrity anchor only; GM/SM are supplementary Coke tags. Unknown dates remain null.","properties":{"base_revision":{"maximum":2147483646,"minimum":0,"type":"integer"},"content_hash":{"pattern":"^[a-f0-9]{64}$","type":"string"},"duration":{"additionalProperties":false,"properties":{"basis":{"enum":["unknown","recording","user_confirmed","derived_time_range"]},"evidence":{"anyOf":[{"maxLength":500,"minLength":1,"type":"string"},{"type":"null"}]},"scope":{"enum":["meeting","whole_conversation"]},"seconds":{"anyOf":[{"maximum":604800,"minimum":1,"type":"integer"},{"type":"null"}]}},"required":["seconds","basis","scope","evidence"],"type":"object"},"exported_at":{"maxLength":40,"pattern":"^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,6})?(Z|[+-][0-9]{2}:[0-9]{2})$","type":"string"},"external_ids":{"items":{"maxLength":240,"minLength":1,"type":"string"},"maxItems":30,"minItems":1,"type":"array","uniqueItems":true},"kind":{"enum":["project_meeting","jour_fixe"]},"meeting_id":{"pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$","type":"string"},"note_created_on":{"anyOf":[{"pattern":"^20[0-9]{2}-[0-9]{2}-[0-9]{2}$","type":"string"},{"type":"null"}]},"note_updated_at":{"anyOf":[{"maxLength":40,"pattern":"^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,6})?(Z|[+-][0-9]{2}:[0-9]{2})$","type":"string"},{"type":"null"}]},"occurred":{"additionalProperties":false,"properties":{"day":{"anyOf":[{"pattern":"^20[0-9]{2}-[0-9]{2}-[0-9]{2}$","type":"string"},{"type":"null"}]},"ends_at":{"anyOf":[{"maxLength":40,"pattern":"^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,6})?(Z|[+-][0-9]{2}:[0-9]{2})$","type":"string"},{"type":"null"}]},"precision":{"enum":["unknown","day","minute"]},"source_note":{"maxLength":500,"minLength":1,"type":"string"},"starts_at":{"anyOf":[{"maxLength":40,"pattern":"^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,6})?(Z|[+-][0-9]{2}:[0-9]{2})$","type":"string"},{"type":"null"}]},"status":{"enum":["confirmed","source_reported","unknown"]},"timezone":{"const":"Europe/Vienna"}},"required":["day","starts_at","ends_at","timezone","precision","status","source_note"],"type":"object"},"organization":{"const":"salescrew"},"owner_id":{"const":"e68b62cd-06b3-4300-8a16-dc04e20ed75d"},"participants":{"items":{"additionalProperties":false,"properties":{"evidence":{"maxLength":300,"minLength":1,"type":"string"},"name":{"maxLength":120,"minLength":1,"type":"string"}},"required":["name","evidence"],"type":"object"},"maxItems":40,"type":"array"},"record_type":{"const":"held_meeting"},"revision":{"maximum":2147483647,"minimum":1,"type":"integer"},"revision_reason":{"maxLength":500,"minLength":1,"type":"string"},"schema_version":{"const":"salescrew.meeting.v1"},"sections":{"items":{"additionalProperties":false,"properties":{"actions":{"items":{"additionalProperties":false,"properties":{"card_id":{"anyOf":[{"pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$","type":"string"},{"type":"null"}]},"due_date":{"anyOf":[{"pattern":"^20[0-9]{2}-[0-9]{2}-[0-9]{2}$","type":"string"},{"type":"null"}]},"id":{"maxLength":80,"minLength":1,"type":"string"},"owner":{"anyOf":[{"maxLength":120,"minLength":1,"type":"string"},{"type":"null"}]},"source_ids":{"items":{"maxLength":80,"minLength":1,"type":"string"},"maxItems":30,"minItems":1,"type":"array","uniqueItems":true},"task":{"maxLength":600,"minLength":1,"type":"string"}},"required":["id","task","owner","due_date","card_id","source_ids"],"type":"object"},"maxItems":20,"type":"array"},"changes":{"items":{"additionalProperties":false,"properties":{"after":{"maxLength":700,"minLength":1,"type":"string"},"before":{"anyOf":[{"maxLength":700,"minLength":1,"type":"string"},{"type":"null"}]},"comparison_meeting_id":{"anyOf":[{"pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$","type":"string"},{"type":"null"}]},"kind":{"enum":["new","changed","confirmed","deferred","rejected","reopened"]},"reason":{"anyOf":[{"maxLength":600,"minLength":1,"type":"string"},{"type":"null"}]},"source_ids":{"items":{"maxLength":80,"minLength":1,"type":"string"},"maxItems":30,"minItems":1,"type":"array","uniqueItems":true}},"required":["kind","before","after","reason","comparison_meeting_id","source_ids"],"type":"object"},"maxItems":8,"type":"array"},"comparison":{"additionalProperties":false,"properties":{"note":{"maxLength":700,"minLength":1,"type":"string"},"previous_meeting_id":{"anyOf":[{"pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$","type":"string"},{"type":"null"}]},"status":{"enum":["baseline","reviewed","unresolved"]}},"required":["previous_meeting_id","status","note"],"type":"object"},"content_scope":{"enum":["single_project","allowed_excerpt","jour_fixe"]},"followups":{"items":{"additionalProperties":false,"properties":{"date":{"anyOf":[{"pattern":"^20[0-9]{2}-[0-9]{2}-[0-9]{2}$","type":"string"},{"type":"null"}]},"kind":{"enum":["clarification","work_order","topic_added","implementation_evidence"]},"source_ids":{"items":{"maxLength":80,"minLength":1,"type":"string"},"maxItems":30,"minItems":1,"type":"array","uniqueItems":true},"text":{"maxLength":1200,"minLength":1,"type":"string"},"verification":{"enum":["user_confirmed","source_reported","locally_verified","production_verified","unverified"]}},"required":["date","kind","text","verification","source_ids"],"type":"object"},"maxItems":30,"type":"array"},"label_ids":{"items":{"pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$","type":"string"},"maxItems":20,"type":"array","uniqueItems":true},"markdown":{"maxLength":500000,"minLength":1,"type":"string"},"note_ref":{"maxLength":300,"minLength":1,"type":"string"},"presentation":{"additionalProperties":false,"properties":{"blocker":{"anyOf":[{"additionalProperties":false,"properties":{"source_ids":{"items":{"maxLength":80,"minLength":1,"type":"string"},"maxItems":30,"minItems":1,"type":"array","uniqueItems":true},"text":{"maxLength":600,"minLength":1,"type":"string"}},"required":["text","source_ids"],"type":"object"},{"type":"null"}]},"decisions":{"items":{"additionalProperties":false,"properties":{"source_ids":{"items":{"maxLength":80,"minLength":1,"type":"string"},"maxItems":30,"minItems":1,"type":"array","uniqueItems":true},"text":{"maxLength":600,"minLength":1,"type":"string"}},"required":["text","source_ids"],"type":"object"},"maxItems":8,"type":"array"},"headlines":{"items":{"maxLength":80,"minLength":1,"type":"string"},"maxItems":3,"type":"array"},"highlight":{"anyOf":[{"maxLength":80,"minLength":1,"type":"string"},{"type":"null"}]},"summary":{"maxLength":1200,"minLength":1,"type":"string"},"title":{"maxLength":120,"minLength":1,"type":"string"}},"required":["title","headlines","highlight","summary","blocker","decisions"],"type":"object"},"primary_label_id":{"anyOf":[{"pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$","type":"string"},{"type":"null"}]},"project_id":{"anyOf":[{"pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$","type":"string"},{"type":"null"}]},"scope_review":{"additionalProperties":false,"properties":{"note":{"maxLength":500,"minLength":1,"type":"string"},"reviewed_by":{"const":"Kilian/Codex"},"status":{"const":"passed"}},"required":["status","reviewed_by","note"],"type":"object"},"section_id":{"pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$","type":"string"},"sources":{"items":{"additionalProperties":false,"properties":{"id":{"maxLength":80,"minLength":1,"type":"string"},"label":{"maxLength":180,"minLength":1,"type":"string"},"locator":{"anyOf":[{"maxLength":160,"minLength":1,"type":"string"},{"type":"null"}]},"note_ref":{"maxLength":300,"minLength":1,"type":"string"},"type":{"enum":["transcript","individual_note","user_clarification","implementation_note","chat_report"]},"verification":{"enum":["user_confirmed","source_reported","locally_verified","production_verified","unverified"]}},"required":["id","type","note_ref","locator","label","verification"],"type":"object"},"maxItems":100,"minItems":1,"type":"array"}},"required":["section_id","project_id","label_ids","note_ref","content_scope","scope_review","presentation","comparison","changes","actions","followups","sources","markdown","primary_label_id"],"type":"object"},"maxItems":8,"minItems":1,"type":"array"},"title":{"maxLength":120,"minLength":1,"type":"string"},"transcript_fingerprints":{"items":{"additionalProperties":false,"properties":{"method":{"enum":["clipboard_bytes_sha256","legacy_trimmed_sha256","excerpt_bytes_sha256"]},"note_ref":{"maxLength":300,"minLength":1,"type":"string"},"sha256":{"pattern":"^[a-f0-9]{64}$","type":"string"}},"required":["sha256","method","note_ref"],"type":"object"},"maxItems":20,"type":"array"},"workspace_id":{"const":"2bb0db3c-9ec4-4066-8f58-0a7712fb6325"}},"required":["schema_version","meeting_id","owner_id","workspace_id","organization","kind","title","external_ids","transcript_fingerprints","occurred","participants","duration","note_created_on","note_updated_at","exported_at","base_revision","revision","revision_reason","content_hash","sections","record_type"],"title":"SalesCrew SIMPL private meeting export v1","type":"object"}$schema$::json, 'f2bd9dce887063926dd71ff84bdebf03b143bb6b23d1d34f2c00c93bcd851ef1');

create table private.personal_meeting_label_targets(primary_label_id uuid primary key references public.labels(id), project_id uuid not null references public.columns(id));
alter table private.personal_meeting_label_targets enable row level security;
revoke all on private.personal_meeting_label_targets from public,anon,authenticated,service_role;
insert into private.personal_meeting_label_targets values
 ('b8f71d57-9822-5aba-a977-d3dc7ff95655','f3ae831b-bb76-4c18-abac-d3b9a6e9be3e'),
 ('ebf05b9e-4ab2-5e5c-a94e-2f988c15ab8e','1ae22cf3-be55-4307-817e-c9dc87143b0d'),
 ('87b09cf1-2557-4c94-923d-5329fc2db9d6','52088588-a24f-4805-892b-2349d7370631'),
 ('8b97b68c-57fa-503f-a92d-a722ccc23626','14a2497d-5444-4b6f-8cc2-d9043c05d88b'),
 ('587b794f-b1ea-53b4-ad2c-3c4cdef36b92','7ac50ae1-e310-4ed6-942e-d13854cb87e7'),
 ('5df72174-f609-4eeb-a5ea-c3dd585f298e','193a7bd5-b6bf-4d5f-96ba-ef2122bfd67a');

create function private.meeting_canonical_json(p jsonb) returns text language sql immutable set search_path='' as $f$
 select case jsonb_typeof(p)
 when 'object' then '{'||coalesce((select string_agg(to_jsonb(key)::text||':'||private.meeting_canonical_json(value),',' order by key collate "C") from jsonb_each(p)),'')||'}'
 when 'array' then '['||coalesce((select string_agg(private.meeting_canonical_json(value),',' order by ord) from jsonb_array_elements(p) with ordinality as a(value,ord)),'')||']'
 else p::text end;
$f$;
create function private.meeting_payload_hash_v1(p jsonb) returns text language sql immutable set search_path='' as $f$
 select encode(sha256(convert_to(private.meeting_canonical_json(p-array['content_hash','exported_at','revision','base_revision']),'UTF8')),'hex');
$f$;
-- Text guard complements the producer's mandatory semantic scope review. No outbound calls.
create function private.meeting_content_allowed_v1(p jsonb) returns boolean language plpgsql immutable set search_path='' as $f$
declare s text:=lower(normalize(p::text,NFKC)); i integer; j integer;
begin
 s:=translate(s,U&'\200B\200C\200D\FEFF','');
 for j in 1..3 loop
  if s like '%\%00%' escape '\' then return false; end if;
  for i in 1..127 loop s:=replace(s,'%'||lpad(to_hex(i),2,'0'),chr(i)); end loop;
  s:=lower(s);
 end loop;
 return s !~ '(s[[:space:]_./-]*academy|(^|[^a-z])sak([^a-z]|$))';
end;$f$;
create function private.can_read_personal_meetings() returns boolean language sql stable security definer set search_path='' as $f$
 select auth.uid()='e68b62cd-06b3-4300-8a16-dc04e20ed75d'::uuid
  and private.has_password_access()
  and private.user_can_access_workspace(auth.uid(),'2bb0db3c-9ec4-4066-8f58-0a7712fb6325'::uuid);
$f$;
revoke all on function private.can_read_personal_meetings() from public,anon,service_role;
grant execute on function private.can_read_personal_meetings() to authenticated;

create table public.personal_meetings (
 id uuid primary key, owner_id uuid not null references public.profiles(id), workspace_id uuid not null references public.workspaces(id),
 kind text not null check(kind in ('project_meeting','jour_fixe')), title text not null check(length(title) between 1 and 120),
 meeting_date date, starts_at timestamptz, ends_at timestamptz, date_precision text not null check(date_precision in ('unknown','day','minute')),
 date_status text not null check(date_status in ('confirmed','source_reported','unknown')), timezone text not null check(timezone='Europe/Vienna'),
 revision integer not null check(revision>0), content_hash text not null check(content_hash~'^[a-f0-9]{64}$'),
 note_created_on date, note_updated_at timestamptz, metadata jsonb not null,
 created_at timestamptz not null default now(), synced_at timestamptz not null default now(),
 check(owner_id='e68b62cd-06b3-4300-8a16-dc04e20ed75d'::uuid and workspace_id='2bb0db3c-9ec4-4066-8f58-0a7712fb6325'::uuid),
 check((date_precision='unknown' and meeting_date is null and starts_at is null and ends_at is null) or (date_precision='day' and meeting_date is not null and starts_at is null and ends_at is null) or (date_precision='minute' and meeting_date is not null and starts_at is not null)),
 check(ends_at is null or ends_at>=starts_at), unique(id,owner_id,workspace_id)
);
create index personal_meetings_owner_date on public.personal_meetings(owner_id,workspace_id,meeting_date,id);
create index personal_meetings_kind_date on public.personal_meetings(owner_id,workspace_id,kind,meeting_date);
create table public.personal_meeting_sections (
 section_id uuid primary key, meeting_id uuid not null, owner_id uuid not null, workspace_id uuid not null,
 project_id uuid references public.columns(id), primary_label_id uuid references public.labels(id), label_ids uuid[] not null, note_ref text not null,
 presentation jsonb not null, comparison jsonb not null, changes jsonb not null, actions jsonb not null, followups jsonb not null, sources jsonb not null,
 markdown text not null check(length(markdown) between 1 and 500000), content_scope text not null, comparison_review_required boolean not null default false,
 foreign key(meeting_id,owner_id,workspace_id) references public.personal_meetings(id,owner_id,workspace_id),
 unique(owner_id,workspace_id,note_ref), unique(meeting_id,section_id)
);
create index personal_meeting_sections_project on public.personal_meeting_sections(owner_id,workspace_id,primary_label_id,meeting_id);
create table public.personal_meeting_aliases (
 owner_id uuid not null, workspace_id uuid not null, external_id text not null, meeting_id uuid not null,
 primary key(owner_id,workspace_id,external_id), foreign key(meeting_id,owner_id,workspace_id) references public.personal_meetings(id,owner_id,workspace_id)
);
create index personal_meeting_aliases_meeting on public.personal_meeting_aliases(meeting_id);
create table public.personal_meeting_revisions (
 meeting_id uuid not null, owner_id uuid not null, workspace_id uuid not null, revision integer not null,
 content_hash text not null, reason text not null, export jsonb not null, synced_at timestamptz not null default now(),
 primary key(meeting_id,revision), foreign key(meeting_id,owner_id,workspace_id) references public.personal_meetings(id,owner_id,workspace_id)
);
create table public.personal_meeting_links (
 meeting_id uuid not null, section_id uuid not null, target_meeting_id uuid not null references public.personal_meetings(id),
 owner_id uuid not null, workspace_id uuid not null, primary key(meeting_id,section_id,target_meeting_id),
 foreign key(meeting_id,section_id) references public.personal_meeting_sections(meeting_id,section_id),
 foreign key(meeting_id,owner_id,workspace_id) references public.personal_meetings(id,owner_id,workspace_id), check(meeting_id<>target_meeting_id)
);
create index personal_meeting_links_target on public.personal_meeting_links(target_meeting_id);
DO $policies$ declare t text; begin
 foreach t in array array['personal_meetings','personal_meeting_sections','personal_meeting_aliases','personal_meeting_revisions','personal_meeting_links'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('alter table public.%I force row level security',t);
  execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);
  execute format('grant select on public.%I to authenticated',t);
  execute format('create policy owner_only on public.%I for select to authenticated using (owner_id=(select auth.uid()) and workspace_id=''2bb0db3c-9ec4-4066-8f58-0a7712fb6325''::uuid and (select private.can_read_personal_meetings()))',t);
 end loop;
end;$policies$;

-- Only privileged, explicitly authorized workflow calls this invoker. Public wrapper checks the verified app identity first.
create function private.apply_personal_meeting_v1(p_export jsonb,p_dry_run boolean default true) returns jsonb language plpgsql security invoker set search_path='' as $f$
declare c json; m public.personal_meetings%rowtype; item jsonb; ref text; target uuid; mid uuid; own uuid:='e68b62cd-06b3-4300-8a16-dc04e20ed75d'; ws uuid:='2bb0db3c-9ec4-4066-8f58-0a7712fb6325'; day date; start_time timestamptz; end_time timestamptz; next_rev integer; affected uuid[]:=array[]::uuid[];
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
  if exists(select 1 from jsonb_array_elements(item->'actions') a where a->>'card_id' is not null and not exists(select 1 from public.cards where id=(a->>'card_id')::uuid and workspace_id=ws and deleted_at is null and (item->>'project_id' is null or project_id=(item->>'project_id')::uuid))) then raise exception using errcode='P0001',message='MEETING_CARD_INVALID'; end if;
  if (select count(distinct s->>'id') from jsonb_array_elements(item->'sources') s)<>jsonb_array_length(item->'sources') then raise exception using errcode='P0001',message='MEETING_SOURCE_INVALID'; end if;
  for ref in select jsonb_array_elements_text(q.value) from jsonb_path_query(item,'$.**.source_ids') q(value) loop
   if not exists(select 1 from jsonb_array_elements(item->'sources') source where source->>'id'=ref) then raise exception using errcode='P0001',message='MEETING_SOURCE_INVALID'; end if;
  end loop;
  for target in select distinct x::uuid from (select item#>>'{comparison,previous_meeting_id}' x union all select v->>'comparison_meeting_id' from jsonb_array_elements(item->'changes') v) refs where x is not null loop
   if target=mid or not exists(select 1 from public.personal_meetings pm join public.personal_meeting_sections ps on ps.meeting_id=pm.id where pm.id=target and pm.owner_id=own and pm.workspace_id=ws and pm.kind=p_export->>'kind' and ps.primary_label_id is not distinct from (item->>'primary_label_id')::uuid and (day is null or pm.meeting_date<=day)) then raise exception using errcode='P0001',message='MEETING_COMPARISON_INVALID'; end if;
  end loop;
 end loop;
 next_rev:=coalesce(m.revision,0)+1;
 if p_dry_run then return jsonb_build_object('status','validated','meeting_id',mid,'revision',next_rev,'content_hash',p_export->>'content_hash','dry_run',true); end if;
 insert into public.personal_meetings(id,owner_id,workspace_id,kind,title,meeting_date,starts_at,ends_at,date_precision,date_status,timezone,revision,content_hash,note_created_on,note_updated_at,metadata)
 values(mid,own,ws,p_export->>'kind',p_export->>'title',day,start_time,end_time,p_export#>>'{occurred,precision}',p_export#>>'{occurred,status}','Europe/Vienna',next_rev,p_export->>'content_hash',(p_export->>'note_created_on')::date,(p_export->>'note_updated_at')::timestamptz,p_export-array['sections','base_revision','revision','content_hash','exported_at'])
 on conflict(id) do update set title=excluded.title,meeting_date=excluded.meeting_date,starts_at=excluded.starts_at,ends_at=excluded.ends_at,date_precision=excluded.date_precision,date_status=excluded.date_status,revision=excluded.revision,content_hash=excluded.content_hash,note_updated_at=excluded.note_updated_at,metadata=excluded.metadata,synced_at=now();
 for item in select value from jsonb_array_elements(p_export->'sections') loop
  insert into public.personal_meeting_sections(section_id,meeting_id,owner_id,workspace_id,project_id,primary_label_id,label_ids,note_ref,presentation,comparison,changes,actions,followups,sources,markdown,content_scope)
  values((item->>'section_id')::uuid,mid,own,ws,(item->>'project_id')::uuid,(item->>'primary_label_id')::uuid,array(select jsonb_array_elements_text(item->'label_ids'))::uuid[],item->>'note_ref',item->'presentation',item->'comparison',item->'changes',item->'actions',item->'followups',item->'sources',item->>'markdown',item->>'content_scope')
  on conflict(section_id) do update set project_id=excluded.project_id,primary_label_id=excluded.primary_label_id,label_ids=excluded.label_ids,note_ref=excluded.note_ref,presentation=excluded.presentation,comparison=excluded.comparison,changes=excluded.changes,actions=excluded.actions,followups=excluded.followups,sources=excluded.sources,markdown=excluded.markdown,content_scope=excluded.content_scope,comparison_review_required=false;
  delete from public.personal_meeting_links where meeting_id=mid and section_id=(item->>'section_id')::uuid;
  insert into public.personal_meeting_links(meeting_id,section_id,target_meeting_id,owner_id,workspace_id)
   select mid,(item->>'section_id')::uuid,x::uuid,own,ws from (select item#>>'{comparison,previous_meeting_id}' x union select v->>'comparison_meeting_id' from jsonb_array_elements(item->'changes') v) refs where x is not null;
 end loop;
 insert into public.personal_meeting_aliases select own,ws,value,mid from jsonb_array_elements_text(p_export->'external_ids') on conflict do nothing;
 insert into public.personal_meeting_revisions values(mid,own,ws,next_rev,p_export->>'content_hash',p_export->>'revision_reason',p_export,now());
 if m.id is null or m.meeting_date is distinct from day then
  with changed as (update public.personal_meeting_sections ps set comparison_review_required=true from public.personal_meetings pm where ps.meeting_id=pm.id and pm.id<>mid and pm.meeting_date>day and pm.kind=p_export->>'kind' and exists(select 1 from public.personal_meeting_sections current_section where current_section.meeting_id=mid and current_section.primary_label_id is not distinct from ps.primary_label_id) returning ps.meeting_id) select coalesce(array_agg(distinct meeting_id),array[]::uuid[]) into affected from changed;
 end if;
 update public.access_revisions set board_version=board_version+1 where id=own;
 return jsonb_build_object('status',case when m.id is null then 'created' else 'updated' end,'meeting_id',mid,'revision',next_rev,'content_hash',p_export->>'content_hash','dry_run',false,'comparison_review_meeting_ids',affected);
end;$f$;
revoke all on function private.apply_personal_meeting_v1(jsonb,boolean) from public,anon,authenticated,service_role;

create function private.sync_personal_meeting_as_owner_v1(p_export jsonb,p_dry_run boolean) returns jsonb language plpgsql security definer set search_path='' as $f$
begin
 if not coalesce(private.can_read_personal_meetings(),false) then raise exception using errcode='42501',message='MEETING_ACCESS_DENIED'; end if;
 return private.apply_personal_meeting_v1(p_export,p_dry_run);
end;$f$;
revoke all on function private.sync_personal_meeting_as_owner_v1(jsonb,boolean) from public,anon,service_role;
grant execute on function private.sync_personal_meeting_as_owner_v1(jsonb,boolean) to authenticated;
create function public.sync_personal_meeting_v1(p_export jsonb,p_dry_run boolean default true) returns jsonb language sql security invoker set search_path='' as $f$
 select private.sync_personal_meeting_as_owner_v1(p_export,p_dry_run);
$f$;
revoke all on function public.sync_personal_meeting_v1(jsonb,boolean) from public,anon,service_role;
grant execute on function public.sync_personal_meeting_v1(jsonb,boolean) to authenticated;

-- Management connector workflow: invoker rights only, postgres-only EXECUTE. No forged JWT or elevated app key.
create function private.sync_personal_meetings_v1(p_exports jsonb,p_dry_run boolean default true) returns jsonb language plpgsql security invoker set search_path='' as $f$
declare item jsonb; results jsonb:='[]';
begin
 if current_user<>'postgres' then raise exception using errcode='42501',message='MEETING_ACCESS_DENIED'; end if;
 if jsonb_typeof(p_exports)<>'array' or jsonb_array_length(p_exports) not between 1 and 10 then raise exception using errcode='P0001',message='MEETING_BATCH_INVALID'; end if;
 begin
  for item in select value from jsonb_array_elements(p_exports) loop results:=results||jsonb_build_array(private.apply_personal_meeting_v1(item,false)); end loop;
  if p_dry_run then raise exception using errcode='P0999',message='MEETING_DRY_RUN_ROLLBACK'; end if;
 exception when sqlstate 'P0999' then null;
 end;
 return jsonb_build_object('schema_version','salescrew.meeting.v1','dry_run',p_dry_run,'results',results);
end;$f$;
revoke all on function private.sync_personal_meetings_v1(jsonb,boolean) from public,anon,authenticated,service_role;
grant execute on function private.sync_personal_meetings_v1(jsonb,boolean) to postgres;

create function private.personal_meeting_sync_readiness_v1() returns jsonb language sql stable security invoker set search_path='' as $f$
 select jsonb_build_object('ready',exists(select 1 from public.profiles where id='e68b62cd-06b3-4300-8a16-dc04e20ed75d'::uuid and lower(email)='kilian.sternath@salescrew.at' and active) and private.user_can_access_workspace('e68b62cd-06b3-4300-8a16-dc04e20ed75d'::uuid,'2bb0db3c-9ec4-4066-8f58-0a7712fb6325'::uuid),'schema_version',version,'schema_hash',schema_hash,'max_payload_bytes',1048576,'max_batch',10,'label_targets',(select jsonb_agg(jsonb_build_object('primary_label_id',l.id,'label',l.name,'color',l.color,'project_id',c.id,'project',c.name)) from private.personal_meeting_label_targets t join public.labels l on l.id=t.primary_label_id join public.columns c on c.id=t.project_id where l.workspace_id='2bb0db3c-9ec4-4066-8f58-0a7712fb6325'::uuid and c.workspace_id=l.workspace_id and c.kind='project')) from private.personal_meeting_contracts where version='salescrew.meeting.v1';
$f$;
revoke all on function private.personal_meeting_sync_readiness_v1() from public,anon,authenticated,service_role;
grant execute on function private.personal_meeting_sync_readiness_v1() to postgres;
create function private.personal_meeting_sync_state_v1(p_meeting_id uuid default null,p_external_ids text[] default '{}',p_note_refs text[] default '{}') returns jsonb language sql stable security invoker set search_path='' as $f$
 select coalesce(jsonb_agg(jsonb_build_object('meeting_id',m.id,'revision',m.revision,'content_hash',m.content_hash,'export',r.export)),'[]') from public.personal_meetings m join public.personal_meeting_revisions r on r.meeting_id=m.id and r.revision=m.revision where m.owner_id='e68b62cd-06b3-4300-8a16-dc04e20ed75d'::uuid and m.workspace_id='2bb0db3c-9ec4-4066-8f58-0a7712fb6325'::uuid and (m.id=p_meeting_id or exists(select 1 from public.personal_meeting_aliases a where a.meeting_id=m.id and a.external_id=any(p_external_ids)) or exists(select 1 from public.personal_meeting_sections s where s.meeting_id=m.id and s.note_ref=any(p_note_refs)));
$f$;
revoke all on function private.personal_meeting_sync_state_v1(uuid,text[],text[]) from public,anon,authenticated,service_role;
grant execute on function private.personal_meeting_sync_state_v1(uuid,text[],text[]) to postgres;
revoke all on function private.meeting_canonical_json(jsonb),private.meeting_payload_hash_v1(jsonb),private.meeting_content_allowed_v1(jsonb) from public,anon,authenticated,service_role;

create function private.personal_meeting_contract_as_owner_v1() returns jsonb language plpgsql stable security definer set search_path='' as $f$
begin
 if not coalesce(private.can_read_personal_meetings(),false) then raise exception using errcode='42501',message='MEETING_ACCESS_DENIED'; end if;
 return private.personal_meeting_sync_readiness_v1();
end;$f$;
revoke all on function private.personal_meeting_contract_as_owner_v1() from public,anon,service_role;
grant execute on function private.personal_meeting_contract_as_owner_v1() to authenticated;
create function public.personal_meeting_contract_v1() returns jsonb language sql stable security invoker set search_path='' as $f$
 select private.personal_meeting_contract_as_owner_v1();
$f$;
revoke all on function public.personal_meeting_contract_v1() from public,anon,service_role;
grant execute on function public.personal_meeting_contract_v1() to authenticated;
