-- Supabase's CDN may authorize a byte response through the metadata/HEAD path.
-- Therefore even metadata-only SELECT grants must not be exposed to clients.
-- INSERT remains scoped to active upload reservations; the API reads Storage
-- with server credentials only after checking the caller's public-table RLS.
drop policy card_attachment_download on storage.objects;
