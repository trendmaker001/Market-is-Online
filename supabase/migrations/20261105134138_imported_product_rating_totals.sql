-- Historical rating aggregates supplied by the merchant. No individual reviews are synthesized.
create table private.product_rating_imports (
 product_id uuid primary key references public.products(id) on delete cascade,
 average_rating numeric not null check(average_rating between 1 and 5),
 rating_count bigint not null check(rating_count>0),
 source_note text not null,
 imported_at timestamptz not null default now()
);
alter table private.product_rating_imports enable row level security;
revoke all on private.product_rating_imports from public,anon,authenticated;
create function private.product_rating_totals(p_product uuid) returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('count',n.count+coalesce(h.rating_count,0),'average',round((coalesce(n.total,0)+coalesce(h.average_rating*h.rating_count,0))/nullif(n.count+coalesce(h.rating_count,0),0),2),'review_count',n.count)
 from (select count(*) as count,sum(rating) as total from private.product_feedback where product_id=p_product) n
 left join private.product_rating_imports h on h.product_id=p_product
$$;
revoke all on function private.product_rating_totals(uuid) from public,anon,authenticated;
create or replace function public.marketplace_rating_summaries(p_ids uuid[])
returns table(product_id uuid,rating_count bigint,average_rating numeric)
language sql stable security definer set search_path='' as $$
 select p.id,(t.value->>'count')::bigint,(t.value->>'average')::numeric from public.products p join public.vendors v on v.id=p.vendor_id
 cross join lateral (select private.product_rating_totals(p.id) as value) t
 where p.id=any(p_ids[1:1000]) and p.status='approved' and v.status='active' and (t.value->>'count')::bigint>0
$$;
create or replace function public.marketplace_product_reviews(p_product_id uuid,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; begin
 if not exists(select 1 from public.products p join public.vendors v on v.id=p.vendor_id where p.id=p_product_id and p.status='approved' and v.status='active') then raise exception 'Product unavailable'; end if;
 result:=private.product_rating_totals(p_product_id);
 return result || jsonb_build_object('reviews',coalesce((select jsonb_agg(jsonb_build_object('rating',r.rating,'body',r.body,'created_at',r.created_at,'updated_at',r.updated_at,'is_mine',coalesce(r.user_id=auth.uid(),false)) order by r.created_at desc,r.user_id) from (select * from private.product_feedback where product_id=p_product_id order by created_at desc,user_id offset greatest(0,least(coalesce(p_offset,0),100000)) limit 20) r),'[]'::jsonb),'mine',(select jsonb_build_object('rating',rating,'body',body) from private.product_feedback where product_id=p_product_id and user_id=auth.uid()));
end $$;
create or replace function public.submit_product_review(p_product_id uuid,p_rating integer,p_body text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in to rate your purchase'; end if;
 if not exists(select 1 from public.orders o join public.order_items i on i.order_id=o.id where o.buyer_id=auth.uid() and o.status='delivered' and i.product_id=p_product_id and coalesce(i.fulfillment_status,'') not in ('returned','cancelled')) then raise exception 'Only the buyer of a delivered product can give a rating'; end if;
 if p_rating is null or p_rating not between 1 and 5 or char_length(coalesce(p_body,''))>2000 then raise exception 'Choose 1–5 stars and no more than 2000 characters'; end if;
 insert into private.product_feedback(product_id,user_id,rating,body) values(p_product_id,auth.uid(),p_rating,trim(coalesce(p_body,''))) on conflict(product_id,user_id) do update set rating=excluded.rating,body=excluded.body,updated_at=now();
 return private.product_rating_totals(p_product_id);
end $$;

-- Import supplied totals by unique product name and vendor, preserving existing buyer feedback.
do $$
declare item jsonb; product uuid; matches integer; begin
 for item in select value from jsonb_array_elements('[["Allure 100% Natural Castor Oil", 4.8, 127], ["Allure 100% Natural Jojoba Oil", 4.6, 84], ["Allure Rosemary Hair & Scalp Oil", 4.9, 143], ["Premium Beard Growth Oil", 4.5, 67], ["100% Natural Tea Tree Oil", 4.7, 112], ["100% Pure Moroccan Argan Oil", 4.8, 95], ["Acid & Retinol Hydrating Cream", 4.4, 53], ["Aloe Vera Hydrating Face Wash", 4.6, 138], ["Anti-Acne Clarifying Serum", 4.9, 76], ["Anti-Acne Clear Gel", 4.3, 41], ["Apricot Radiance Scrub", 4.7, 109], ["Charcoal Deep Cleansing Scrub", 4.5, 88], ["Charcoal Face Wash", 4.8, 131], ["Cocoa Butter Lotion", 4.6, 72], ["Hand & Nail Repair Balm", 4.2, 34], ["Hyaluronic Acid Serum", 4.9, 126], ["Hydra Boost Gel", 4.7, 93], ["Mud Mask", 4.4, 58], ["Neem Luxe Purifying Face Wash", 4.8, 117], ["Quick Fix Urgent Facial", 4.5, 46], ["Rapid Dark Circles Illuminating Eye Cream", 4.6, 81], ["Rose Water Face Mist", 4.9, 139], ["Sun Block SPF 50", 4.7, 104], ["Vitamin C Brightening Cream", 4.8, 91], ["Vitamin C Brightening Face Wash", 4.3, 63], ["Vitamin C Brightening Moisturiser", 4.6, 122], ["Vitamin E Intensive Moisturizing Cream", 4.5, 37], ["Vitamin E Nourishing Oil", 4.9, 114]]'::jsonb) loop
  select count(*) into matches from public.products p join public.vendors v on v.id=p.vendor_id where v.business_name='Allure Care' and lower(regexp_replace(trim(p.name),'\s+',' ','g'))=lower(item->>0);
  if matches<>1 then raise exception 'Expected one Allure Care product for %, found %',item->>0,matches; end if;
  select p.id into product from public.products p join public.vendors v on v.id=p.vendor_id where v.business_name='Allure Care' and lower(regexp_replace(trim(p.name),'\s+',' ','g'))=lower(item->>0);
  insert into private.product_rating_imports(product_id,average_rating,rating_count,source_note) values(product,(item->>1)::numeric,(item->>2)::bigint,'Merchant-supplied historical rating totals, 2026-11-05');
 end loop;
end $$;
