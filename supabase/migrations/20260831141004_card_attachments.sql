-- Private card files. Client writes reserve metadata through the authenticated API.
create table public.attachments (
  id uuid primary key default gen_random_uuid(),
  card_id uuid not null references public.cards(id) on delete restrict,
  uploaded_by uuid not null references public.profiles(id) on delete restrict,
  filename text not null check (length(filename) between 1 and 180 and filename !~ '[[:cntrl:]/\\]'),
  mime_type text not null,
  size_bytes integer not null check (size_bytes between 1 and 20971520),
  object_path text generated always as (card_id::text || '/' || id::text) stored unique,
  status text not null default 'pending' check (status in ('pending','ready','deleting')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '15 minutes'
);
create index attachments_card_idx on public.attachments(card_id);
create index attachments_uploader_idx on public.attachments(uploaded_by);
create index attachments_cleanup_idx on public.attachments(expires_at) where status <> 'ready';
alter table public.attachments enable row level security;
revoke all on public.attachments from anon, authenticated;
grant select on public.attachments to authenticated;
grant all on public.attachments to service_role;
create policy attachments_read on public.attachments for select to authenticated
using ((select private.is_member()) and (status = 'ready' or uploaded_by = (select auth.uid())));

-- Lock the parent so simultaneous reservations cannot exceed the per-card limit.
create function private.limit_card_attachments() returns trigger language plpgsql
security definer set search_path = '' as $$
begin
  perform 1 from public.cards where id = new.card_id for update;
  if (select count(*) from public.attachments where card_id = new.card_id) >= 20 then
    raise exception 'ATTACHMENT_LIMIT' using errcode = '23514';
  end if;
  return new;
end;
$$;
revoke all on function private.limit_card_attachments() from public, anon, authenticated;
create trigger attachments_limit before insert on public.attachments
for each row execute function private.limit_card_attachments();

-- A shared row lock serializes Storage insertion with cancellation/deletion.
create function private.can_upload_attachment(path text) returns boolean language plpgsql
security definer set search_path = '' as $$
declare a public.attachments;
begin
  if not private.is_member() then return false; end if;
  select * into a from public.attachments where object_path = path for share;
  return coalesce(a.uploaded_by = auth.uid() and a.status = 'pending' and a.expires_at > now(), false);
end;
$$;
revoke all on function private.can_upload_attachment(text) from public, anon;
grant execute on function private.can_upload_attachment(text) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('card-attachments','card-attachments',false,20971520,array[
  'image/png','image/jpeg','image/webp','image/gif','application/pdf',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'text/plain','text/csv','text/markdown','application/zip'
]);
create policy card_attachment_upload on storage.objects for insert to authenticated
with check (bucket_id = 'card-attachments' and private.can_upload_attachment(name));
create policy card_attachment_download on storage.objects for select to authenticated
using (
  bucket_id = 'card-attachments'
  and (select private.is_member())
  and storage.allow_any_operation(array['object.get_authenticated','object.get_authenticated_info'])
  and exists (select 1 from public.attachments a where a.object_path = name
    and (a.status = 'ready' or (a.status = 'pending' and a.uploaded_by = (select auth.uid()))))
);
-- No Storage UPDATE/DELETE or metadata write policy: no overwrites or bypassing finalization.
alter publication supabase_realtime add table public.attachments;
