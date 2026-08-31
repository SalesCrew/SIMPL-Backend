-- Keep metadata and the private bucket aligned at 500 MiB (UI label: MB).
-- The project-wide Storage cap is configured separately in the dashboard.
alter table public.attachments drop constraint attachments_size_bytes_check;
alter table public.attachments add constraint attachments_size_bytes_check
  check (size_bytes between 1 and 524288000);
alter table public.attachments alter column expires_at
  set default (now() + interval '24 hours');

update storage.buckets set file_size_limit = 524288000
where id = 'card-attachments';
