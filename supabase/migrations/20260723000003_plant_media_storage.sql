-- Durable object storage for plant photography.
--
-- Photos currently live as Buffers inside the API process and vanish on redeploy, which
-- breaks the product's core promise that a plant's progress is comparable over time. This
-- moves them into a private Supabase Storage bucket whose object paths are owner-scoped as
-- `<account uuid>/<media asset uuid>`, matching `app.media_assets.storage_key`.

begin;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('plant-media', 'plant-media', false, 8 * 1024 * 1024, array['image/jpeg', 'image/png'])
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- Resolves the account that owns an object path, so policies read the same way as the
-- relational ones and a malformed path simply fails to match rather than matching broadly.
create or replace function app.storage_object_account_id(object_name text)
returns uuid
language plpgsql
immutable
as $$
declare
    first_segment text := (storage.foldername(object_name))[1];
begin
    return first_segment::uuid;
exception
    when invalid_text_representation then
        return null;
end;
$$;

grant execute on function app.storage_object_account_id(text) to authenticated;

drop policy if exists plant_media_owner_write on storage.objects;
create policy plant_media_owner_write on storage.objects
    for all
    using (
        bucket_id = 'plant-media'
        and app.storage_object_account_id(name) = app.current_account_id()
    )
    with check (
        bucket_id = 'plant-media'
        and app.storage_object_account_id(name) = app.current_account_id()
    );

-- Owners must be able to see the photo a sitter took, and a sitter the owner's reference
-- shot, so read access follows the plant rather than the uploader.
drop policy if exists plant_media_plant_read on storage.objects;
create policy plant_media_plant_read on storage.objects
    for select using (
        bucket_id = 'plant-media'
        and exists (
            select 1
            from app.media_assets asset
            where asset.storage_key = storage.objects.name
              and asset.plant_id is not null
              and asset.deleted_at is null
              and app.can_access_plant(asset.plant_id)
        )
    );

commit;
