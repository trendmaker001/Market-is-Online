-- New product photos must pass the authenticated byte/dimension upload service.
-- Existing photo URLs may stay on their original listing when it is edited.
create table private.verified_product_photos(
 url text primary key, vendor_id uuid not null references public.vendors(id),
 actor_id uuid not null references auth.users(id), width integer not null check(width=1000),
 height integer not null check(height=1000), bytes integer not null check(bytes between 1 and 5242880),
 mime text not null check(mime in ('image/jpeg','image/png','image/webp')), created_at timestamptz not null default now()
);
alter table private.verified_product_photos enable row level security;
revoke all on private.verified_product_photos from public,anon,authenticated;
create index verified_product_photos_vendor_idx on private.verified_product_photos(vendor_id);
create index verified_product_photos_actor_idx on private.verified_product_photos(actor_id);

create function public.can_upload_product_photo(p_vendor_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(select 1 from public.vendors where id=p_vendor_id and status='active' and (owner_user_id=auth.uid() or private.has_role('admin')))
$$;
revoke all on function public.can_upload_product_photo(uuid) from public,anon;
grant execute on function public.can_upload_product_photo(uuid) to authenticated;

create function public.record_verified_product_photo(p_vendor_id uuid,p_actor_id uuid,p_url text,p_width integer,p_height integer,p_bytes integer,p_mime text) returns void
language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.vendors v where v.id=p_vendor_id and v.status='active' and (v.owner_user_id=p_actor_id or exists(select 1 from public.user_roles r where r.user_id=p_actor_id and r.role='admin'))) then raise exception 'Active seller access required'; end if;
 if p_url !~ ('^https://[a-z0-9.-]+/storage/v1/object/public/product-images/'||p_vendor_id::text||'/[a-f0-9-]+\.(jpg|png|webp)$') then raise exception 'Invalid product photo location'; end if;
 insert into private.verified_product_photos(url,vendor_id,actor_id,width,height,bytes,mime) values(p_url,p_vendor_id,p_actor_id,p_width,p_height,p_bytes,p_mime);
end $$;
revoke all on function public.record_verified_product_photo(uuid,uuid,text,integer,integer,integer,text) from public,anon,authenticated;
grant execute on function public.record_verified_product_photo(uuid,uuid,text,integer,integer,integer,text) to service_role;

create function private.require_verified_product_photos() returns trigger
language plpgsql security definer set search_path='' as $$
declare photo text; previous jsonb:='[]'::jsonb;
begin
 -- Trusted server imports remain possible; customer RPCs always carry auth.uid().
 if auth.uid() is null then return new; end if;
 if TG_OP='UPDATE' and old.vendor_id=new.vendor_id then previous=coalesce(old.image_urls,'[]'::jsonb);if old.image_url is not null then previous=previous||jsonb_build_array(old.image_url);end if;end if;
 for photo in select value from jsonb_array_elements_text(coalesce(new.image_urls,'[]'::jsonb)||case when new.image_url is null then '[]'::jsonb else jsonb_build_array(new.image_url) end) loop
  if not (previous ? photo) and not exists(select 1 from private.verified_product_photos v where v.url=photo and v.vendor_id=new.vendor_id) then
   raise exception 'Upload new photos through the listing form: exactly 1000 × 1000 pixels, JPG/PNG/WebP, maximum 5 MB each. Refresh the page if you are using an older form.';
  end if;
 end loop;
 return new;
end $$;
revoke all on function private.require_verified_product_photos() from public,anon,authenticated;
create trigger require_verified_product_photos before insert or update of image_urls,image_url,vendor_id on public.products for each row execute function private.require_verified_product_photos();
-- Direct unverified uploads are replaced by the server-side upload service.
drop policy if exists product_photo_upload on storage.objects;
