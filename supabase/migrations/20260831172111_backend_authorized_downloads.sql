-- File bytes go through the authenticated API, which checks live attachment
-- RLS before streaming. Storage's CDN may cache a previous authorized GET even
-- when an object's Cache-Control is no-store. Never authorize client byte GETs.
-- Keep metadata/HEAD access for authenticated resumable-upload verification.
alter policy card_attachment_download on storage.objects using (
  bucket_id = 'card-attachments'
  and storage.allow_only_operation('object.get_authenticated_info')
  and exists (
    select 1 from public.attachments a
    where a.object_path = objects.name
      and (
        a.status = 'ready'
        or (a.status = 'pending' and (
          a.uploaded_by = (select auth.uid()) or (select private.is_admin())
        ))
      )
  )
);
