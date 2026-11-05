-- Expand existing admin-only presentation controls; retain fields from older clients.
create or replace function public.admin_save_marketplace_presentation(p_settings jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare k text; item jsonb; val text; field text; begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 if p_settings is null or jsonb_typeof(p_settings)<>'object' or jsonb_typeof(p_settings->'interval') is distinct from 'number' or (p_settings->>'interval')::numeric not between 3 and 15 or jsonb_typeof(p_settings->'enabled') is distinct from 'boolean' then raise exception 'Choose an enabled state and interval from 3 to 15 seconds'; end if;
 p_settings:=(select settings from private.marketplace_presentation where id)||p_settings;
 if p_settings ? 'main_interval' and (jsonb_typeof(p_settings->'main_interval') is distinct from 'number' or (p_settings->>'main_interval')::numeric not between 3 and 15) then raise exception 'Main rotation must be 3 to 15 seconds'; end if;
 foreach k in array array['main','video','slides','promos','categories'] loop
  if k in ('main','video') and not p_settings ? k then continue; end if;
  if jsonb_typeof(p_settings->k) is distinct from 'array' then raise exception 'Invalid presentation items'; end if;
  if jsonb_array_length(p_settings->k)>(case k when 'main' then 8 when 'video' then 1 when 'slides' then 8 when 'promos' then 2 else 60 end) then raise exception 'Too many presentation items'; end if;
  for item in select value from jsonb_array_elements(p_settings->k) loop
   if jsonb_typeof(item)<>'object' or length(coalesce(item->>'title',''))>120 or jsonb_typeof(item->'enabled') is distinct from 'boolean' then raise exception 'Invalid image details'; end if;
   foreach field in array array['image_url','mobile_url','video_url','mobile_video_url','link'] loop
    val:=coalesce(item->>field,'');
    if length(val)>2000 or (val<>'' and not (val ~ '^https://[^[:space:]]+$' or val ~ '^/[A-Za-z0-9][^[:space:]]*$' or (field='link' and val ~ '^#[^[:space:]]+$'))) then raise exception 'Use an HTTPS URL, site path or internal link'; end if;
   end loop;
   if coalesce(item->>'image_url','')='' then raise exception 'Each item needs an image'; end if;
   if k='video' and coalesce(item->>'video_url','')='' then raise exception 'Add a video URL or upload a video'; end if;
   if k<>'categories' and (item->>'enabled')::boolean and coalesce(item->>'link','')='' then raise exception 'Add a destination link for each active promotion'; end if;
   if k='categories' and length(coalesce(item->>'name','')) not between 1 and 60 then raise exception 'Choose a category name'; end if;
  end loop;
 end loop;
 update private.marketplace_presentation set settings=p_settings,updated_at=now() where id;
 insert into public.audit_logs(actor_id,action,entity_type,after_data) values(auth.uid(),'MARKETPLACE_PRESENTATION_SAVED','marketplace_presentation',p_settings);
 return p_settings;
end $$;
