begin;
-- Reporting is restricted to the authenticated introducing member, including drill-downs.
create or replace function public.my_vendor_report(p_from date default null,p_to date default null,p_vendor uuid default null,p_page integer default 1)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=auth.uid(); result jsonb;
begin
 if u is null or not exists(select 1 from public.member_profiles where user_id=u and status not in('suspended','closed')) then raise exception 'Member access required';end if;
 if p_from>p_to then raise exception 'Start date must not follow end date';end if;
 if p_vendor is not null and not exists(select 1 from public.vendors where id=p_vendor and introduced_by=u) then raise exception 'Vendor access denied';end if;
 with stores as (select id,business_name,status,created_at from public.vendors where introduced_by=u and (p_vendor is null or id=p_vendor)),
 items as (select i.*,o.order_code,o.created_at order_date,o.status::text order_status,o.payment_status::text payment_status,
 (o.status::text='delivered' and o.payment_status::text='confirmed' and i.fulfillment_status not in('cancelled','refunded','returned')) successful
 from public.order_items i join stores v on v.id=i.vendor_id join public.orders o on o.id=i.order_id
 where (p_from is null or o.created_at>=p_from::timestamp at time zone 'Asia/Karachi') and (p_to is null or o.created_at<(p_to+1)::timestamp at time zone 'Asia/Karachi')),
 rewards as (select r.*,i.vendor_id from public.ecommerce_rewards r join items i on i.id=r.order_item_id where r.beneficiary_id=u and r.reward_kind='vendor_introducer'),
 vendor_rows as (select v.*,
 coalesce((select sum(line_total_pkr) from items where vendor_id=v.id and successful),0) sales,
 coalesce((select sum(quantity) from items where vendor_id=v.id and successful),0) units,
 (select count(distinct order_id) from items where vendor_id=v.id) orders,
 coalesce((select sum(amount) from rewards where vendor_id=v.id and status='posted'),0) credited,
 coalesce((select sum(amount) from rewards where vendor_id=v.id and status in('pending_delivery','held_activation')),0) pending from stores v),
 order_rows as (select order_id id,order_code,order_date created_at,order_status status,payment_status,sum(line_total_pkr) amount,
 jsonb_agg(jsonb_build_object('name',product_name_snapshot,'quantity',quantity,'amount',line_total_pkr,'status',fulfillment_status) order by id) items,
 coalesce((select sum(r.amount) from rewards r where r.order_id=i.order_id and r.status='posted'),0) credited,
 coalesce((select sum(r.amount) from rewards r where r.order_id=i.order_id and r.status in('pending_delivery','held_activation')),0) pending
 from items i group by order_id,order_code,order_date,order_status,payment_status)
 select jsonb_build_object('vendors',coalesce((select jsonb_agg(v order by business_name,id) from vendor_rows v),'[]'::jsonb),
 'summary',jsonb_build_object('vendors',(select count(*) from stores),'sales',coalesce((select sum(line_total_pkr) from items where successful),0),'units',coalesce((select sum(quantity) from items where successful),0),'orders',(select count(*) from order_rows),'credited',coalesce((select sum(amount) from rewards where status='posted'),0),'pending',coalesce((select sum(amount) from rewards where status in('pending_delivery','held_activation')),0),'cancelled',(select count(*) from order_rows where status in('cancelled','refunded','returned'))),
 'orders',coalesce((select jsonb_agg(x) from (select * from order_rows order by created_at desc,id limit 50 offset (greatest(1,least(coalesce(p_page,1),100000))-1)*50)x),'[]'::jsonb)) into result;
 return result;
end $$;
revoke all on function public.my_vendor_report(date,date,uuid,integer) from public,anon;
grant execute on function public.my_vendor_report(date,date,uuid,integer) to authenticated;
CREATE OR REPLACE FUNCTION public.submit_vendor_application(p_business text, p_email text, p_phone text, p_categories text, p_description text, p_proposed numeric, p_introducer_code text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare vid uuid; intro uuid; m public.member_profiles%rowtype; consumer boolean; begin
 if coalesce((select config_value from public.system_config where config_key='VENDOR_REGISTRATION' and effective_to is null order by version desc limit 1),'true'::jsonb) <> 'true'::jsonb then raise exception 'Seller registration is currently closed'; end if;
 if auth.uid() is null then raise exception 'Sign in or register with a referral code before applying'; end if;
 select introduced_by into intro from private.vendor_identities where user_id=auth.uid();
 perform 1 from auth.users where id=auth.uid() for update;
 if exists(select 1 from public.member_profiles where user_id=auth.uid() and status in('suspended','closed')) then raise exception 'Account is not active';end if;
 if intro is null then
  select user_id into intro from public.member_profiles where upper(member_code)=upper(trim(p_introducer_code)) and status not in('suspended','closed');
  if intro is null then raise exception 'A valid member vendor invitation is required';end if;
 end if;
 if exists(select 1 from public.vendor_applications where applicant_user_id=auth.uid() and status in('pending','active')) or exists(select 1 from public.vendors where owner_user_id=auth.uid() and status='active') then raise exception 'A vendor account or application already exists';end if;
 if not exists(select 1 from auth.users where id=auth.uid() and email_confirmed_at is not null) then raise exception 'Verify your email before applying';end if;
 if length(trim(coalesce(p_business,''))) not between 2 and 150 or p_email not like '%@%' or length(trim(coalesce(p_phone,'')))<5 or length(trim(coalesce(p_categories,'')))<2 then raise exception 'Complete business details'; end if;
 if p_proposed is null or p_proposed<.05 or p_proposed>1 then raise exception 'Proposed agreement percentage is required (5 to 100 percent)';end if;
 insert into public.vendor_applications(applicant_user_id,business_name,contact_email,contact_phone,categories,description,proposed_commission,introduced_by) values(auth.uid(),trim(p_business),trim(p_email),trim(p_phone),trim(p_categories),p_description,p_proposed,intro) returning id into vid;
 return vid;
end $function$
;

commit;
