-- Review writes require a delivered purchase, including calls from older clients.
create or replace function public.submit_product_review(p_product_id uuid,p_rating integer,p_body text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in to rate your purchase'; end if;
 if not exists(select 1 from public.orders o join public.order_items i on i.order_id=o.id where o.buyer_id=auth.uid() and o.status='delivered' and i.product_id=p_product_id and coalesce(i.fulfillment_status,'') not in ('returned','cancelled')) then raise exception 'Only the buyer of a delivered product can give a rating'; end if;
 if p_rating is null or p_rating not between 1 and 5 or char_length(coalesce(p_body,''))>2000 then raise exception 'Choose 1–5 stars and no more than 2000 characters'; end if;
 insert into private.product_feedback(product_id,user_id,rating,body) values(p_product_id,auth.uid(),p_rating,trim(coalesce(p_body,''))) on conflict(product_id,user_id) do update set rating=excluded.rating,body=excluded.body,updated_at=now();
 return (select jsonb_build_object('count',count(*),'average',round(avg(rating),2)) from private.product_feedback where product_id=p_product_id);
end $$;
create function public.my_order_review_items(p_order_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.orders where id=p_order_id and buyer_id=auth.uid()) then raise exception 'Order unavailable'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('product_id',i.product_id,'name',i.name,'rating',r.rating,'body',r.body) order by i.name) from (select distinct oi.product_id,oi.product_name_snapshot as name from public.order_items oi join public.orders o on o.id=oi.order_id where o.id=p_order_id and o.buyer_id=auth.uid() and o.status='delivered' and coalesce(oi.fulfillment_status,'') not in ('returned','cancelled') and oi.product_id is not null) i left join private.product_feedback r on r.product_id=i.product_id and r.user_id=auth.uid()),'[]'::jsonb);
end $$;
create function public.submit_order_product_review(p_order_id uuid,p_product_id uuid,p_rating integer,p_body text default '') returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.orders o join public.order_items i on i.order_id=o.id where o.id=p_order_id and o.buyer_id=auth.uid() and o.status='delivered' and i.product_id=p_product_id and coalesce(i.fulfillment_status,'') not in ('returned','cancelled')) then raise exception 'A delivered order belonging to you is required'; end if;
 return public.submit_product_review(p_product_id,p_rating,p_body);
end $$;
revoke all on function public.my_order_review_items(uuid),public.submit_order_product_review(uuid,uuid,integer,text),public.submit_product_review(uuid,integer,text) from public,anon,authenticated;
grant execute on function public.my_order_review_items(uuid),public.submit_order_product_review(uuid,uuid,integer,text),public.submit_product_review(uuid,integer,text) to authenticated;

create table private.marketplace_presentation(id boolean primary key default true check(id),settings jsonb not null,updated_at timestamptz not null default now());
alter table private.marketplace_presentation enable row level security;
revoke all on private.marketplace_presentation from public,anon,authenticated;
insert into private.marketplace_presentation(settings) values ('{"enabled":true,"interval":5,"slides":[{"title":"Home and living collection","image_url":"/assets/premium-home-living.webp","link":"#shop","enabled":true},{"title":"Everyday essentials","image_url":"/assets/premium-everyday-tech.webp","link":"#shop","enabled":true}],"promos":[{"title":"Explore our collections","image_url":"/assets/premium-fashion.webp","link":"#shop","enabled":true},{"title":"Discover marketplace finds","image_url":"/assets/premium-home-living.webp","link":"#shop","enabled":true}],"categories":[]}');
create function public.marketplace_presentation_settings() returns jsonb language sql stable security definer set search_path='' as $$ select settings from private.marketplace_presentation where id $$;
create function public.admin_save_marketplace_presentation(p_settings jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare k text; item jsonb; val text; field text; begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 if p_settings is null or jsonb_typeof(p_settings)<>'object' or jsonb_typeof(p_settings->'interval') is distinct from 'number' or (p_settings->>'interval')::numeric not between 3 and 15 or jsonb_typeof(p_settings->'enabled') is distinct from 'boolean' then raise exception 'Choose an enabled state and interval from 3 to 15 seconds'; end if;
 foreach k in array array['slides','promos','categories'] loop
  if jsonb_typeof(p_settings->k) is distinct from 'array' then raise exception 'Invalid presentation items'; end if;
  if jsonb_array_length(p_settings->k)>(case k when 'slides' then 8 when 'promos' then 2 else 60 end) then raise exception 'Too many presentation items'; end if;
  for item in select value from jsonb_array_elements(p_settings->k) loop
   if jsonb_typeof(item)<>'object' or length(coalesce(item->>'title',''))>120 or jsonb_typeof(item->'enabled') is distinct from 'boolean' then raise exception 'Invalid image details'; end if;
   foreach field in array array['image_url','mobile_url','link'] loop
    val:=coalesce(item->>field,'');
    if length(val)>2000 or (val<>'' and not (val ~ '^https://[^[:space:]]+$' or val ~ '^/[A-Za-z0-9][^[:space:]]*$' or (field='link' and val ~ '^#[^[:space:]]+$'))) then raise exception 'Use an HTTPS URL, site path or internal link'; end if;
   end loop;
   if coalesce(item->>'image_url','')='' then raise exception 'Each item needs an image'; end if;
   if k='categories' and length(coalesce(item->>'name','')) not between 1 and 60 then raise exception 'Choose a category name'; end if;
  end loop;
 end loop;
 update private.marketplace_presentation set settings=p_settings,updated_at=now() where id;
 insert into public.audit_logs(actor_id,action,entity_type,after_data) values(auth.uid(),'MARKETPLACE_PRESENTATION_SAVED','marketplace_presentation',p_settings);
 return p_settings;
end $$;
revoke all on function public.marketplace_presentation_settings(),public.admin_save_marketplace_presentation(jsonb) from public,anon,authenticated;
grant execute on function public.marketplace_presentation_settings() to anon,authenticated;
grant execute on function public.admin_save_marketplace_presentation(jsonb) to authenticated;
