-- Customer feedback is stored separately from labelled sample UI values.
create table private.product_feedback (
 product_id uuid not null references public.products(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 rating smallint not null check(rating between 1 and 5),
 body text not null default '' check(char_length(body)<=2000),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 primary key(product_id,user_id)
);
alter table private.product_feedback enable row level security;
create index product_feedback_user_idx on private.product_feedback(user_id);
revoke all on private.product_feedback from public,anon,authenticated;

create function public.marketplace_rating_summaries(p_ids uuid[])
returns table(product_id uuid,rating_count bigint,average_rating numeric)
language sql stable security definer set search_path='' as $$
 select r.product_id,count(*),round(avg(r.rating),2) from private.product_feedback r
 join public.products p on p.id=r.product_id join public.vendors v on v.id=p.vendor_id
 where r.product_id=any(p_ids[1:1000]) and p.status='approved' and v.status='active' group by r.product_id
$$;
create function public.marketplace_product_reviews(p_product_id uuid,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; begin
 if not exists(select 1 from public.products p join public.vendors v on v.id=p.vendor_id where p.id=p_product_id and p.status='approved' and v.status='active') then raise exception 'Product unavailable'; end if;
 select jsonb_build_object('count',count(*),'average',round(avg(rating),2)) into result from private.product_feedback where product_id=p_product_id;
 return result || jsonb_build_object('reviews',coalesce((select jsonb_agg(jsonb_build_object('rating',r.rating,'body',r.body,'created_at',r.created_at,'updated_at',r.updated_at,'is_mine',coalesce(r.user_id=auth.uid(),false)) order by r.created_at desc,r.user_id) from (select * from private.product_feedback where product_id=p_product_id order by created_at desc,user_id offset greatest(0,least(coalesce(p_offset,0),100000)) limit 20) r),'[]'::jsonb),'mine',(select jsonb_build_object('rating',rating,'body',body) from private.product_feedback where product_id=p_product_id and user_id=auth.uid()));
end $$;
create function public.submit_product_review(p_product_id uuid,p_rating integer,p_body text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in to rate a product'; end if;
 if p_rating is null or p_rating not between 1 and 5 or char_length(coalesce(p_body,''))>2000 then raise exception 'Choose 1–5 stars and no more than 2000 characters'; end if;
 if not exists(select 1 from public.products p join public.vendors v on v.id=p.vendor_id where p.id=p_product_id and p.status='approved' and v.status='active') then raise exception 'Product unavailable'; end if;
 insert into private.product_feedback(product_id,user_id,rating,body) values(p_product_id,auth.uid(),p_rating,trim(coalesce(p_body,'')))
 on conflict(product_id,user_id) do update set rating=excluded.rating,body=excluded.body,updated_at=now();
 return public.marketplace_product_reviews(p_product_id,0);
end $$;

create table private.marketplace_ticker (
 id boolean primary key default true check(id), messages jsonb not null, enabled boolean not null default true,
 updated_at timestamptz not null default now()
);
alter table private.marketplace_ticker enable row level security;
revoke all on private.marketplace_ticker from public,anon,authenticated;
insert into private.marketplace_ticker(id,messages) values(true,'["Welcome to Market is Online","Explore products from our marketplace sellers","Manage your shopping and rewards in My Dashboard"]');
create function public.marketplace_ticker_settings() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('messages',messages,'enabled',enabled) from private.marketplace_ticker where id=true
$$;
create function public.admin_save_marketplace_ticker(p_messages jsonb,p_enabled boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 if p_messages is null or jsonb_typeof(p_messages)<>'array' then raise exception 'Provide three messages'; end if;
 if jsonb_array_length(p_messages)<>3 or exists(select 1 from jsonb_array_elements(p_messages) m where jsonb_typeof(m)<>'string' or char_length(trim(m#>>'{}')) not between 1 and 200) then raise exception 'Provide three messages of 1–200 characters'; end if;
 update private.marketplace_ticker set messages=p_messages,enabled=coalesce(p_enabled,true),updated_at=now() where id=true;
 insert into public.audit_logs(actor_id,action,entity_type,after_data) values(auth.uid(),'MARKETPLACE_TICKER_SAVED','marketplace_ticker',jsonb_build_object('messages',p_messages,'enabled',p_enabled));
 return public.marketplace_ticker_settings();
end $$;
revoke all on function public.marketplace_rating_summaries(uuid[]),public.marketplace_product_reviews(uuid,integer),public.submit_product_review(uuid,integer,text),public.marketplace_ticker_settings(),public.admin_save_marketplace_ticker(jsonb,boolean) from public,anon,authenticated;
grant execute on function public.marketplace_rating_summaries(uuid[]),public.marketplace_product_reviews(uuid,integer),public.marketplace_ticker_settings() to anon,authenticated;
grant execute on function public.submit_product_review(uuid,integer,text),public.admin_save_marketplace_ticker(jsonb,boolean) to authenticated;
