-- User referrals and member-network referrals have distinct display codes.
-- Existing ?affiliate=MIO-... links continue to resolve to the same member.
alter table private.customer_identities add column shipping_address text not null default '',add column shipping_city text not null default '';
create function private.resolve_shopping_referral(p_code text) returns uuid language sql stable security definer set search_path='' as $$
 select m.user_id from public.member_profiles m
 where (upper(m.member_code)=regexp_replace(upper(trim(p_code)),'^USR-','MIO-')
 or upper(m.referral_code)=regexp_replace(regexp_replace(upper(trim(p_code)),'^USR-',''),'-[LR]$',''))
 and m.status in('active','inactive') and m.terms_accepted_at is not null limit 1
$$;
revoke all on function private.resolve_shopping_referral(text) from public,anon,authenticated;
create function public.shopping_referral(p_code text) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('code',regexp_replace(m.member_code,'^MIO-','USR-'),'name',m.full_name)
 from public.member_profiles m where m.user_id=private.resolve_shopping_referral(p_code)
$$;
revoke all on function public.shopping_referral(text) from public,anon,authenticated;
grant execute on function public.shopping_referral(text) to anon,authenticated;

create or replace function public.my_shopping_account() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c private.customer_identities%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 select * into c from private.customer_identities where user_id=auth.uid();
 return jsonb_build_object('has_customer',c.user_id is not null,'customer_only',c.user_id is not null and not exists(select 1 from public.member_profiles where user_id=auth.uid()),
 'full_name',c.full_name,'phone',c.phone,'country_code',c.country_code,'shipping_address',c.shipping_address,'shipping_city',c.shipping_city,
 'email',(select email from auth.users where id=auth.uid()),'terms_accepted',c.terms_accepted_at is not null,'has_sponsor',c.sponsor_id is not null,
 'sponsor_code',(select regexp_replace(member_code,'^MIO-','USR-') from public.member_profiles where user_id=c.sponsor_id),
 'sponsor_name',(select full_name from public.member_profiles where user_id=c.sponsor_id));
end $$;
create function public.save_shopping_profile(p_name text,p_phone text,p_country text,p_address text,p_city text,p_consent boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 if length(trim(coalesce(p_name,''))) not between 2 and 120 or length(trim(coalesce(p_phone,''))) not between 7 and 20
 or coalesce(p_country,'')!~'^[A-Z]{2}$' or length(coalesce(p_address,''))>500 or length(coalesce(p_city,''))>100 then raise exception 'Enter valid name, phone, country and delivery details';end if;
 update private.customer_identities set full_name=trim(p_name),phone=trim(p_phone),country_code=p_country,shipping_address=trim(coalesce(p_address,'')),shipping_city=trim(coalesce(p_city,'')),terms_accepted_at=coalesce(terms_accepted_at,case when p_consent then now() end)
 where user_id=auth.uid() and (terms_accepted_at is not null or p_consent is true);
 if not found then raise exception 'Shopping account and terms consent are required';end if;
end $$;
revoke all on function public.save_shopping_profile(text,text,text,text,text,boolean) from public,anon,authenticated;
grant execute on function public.save_shopping_profile(text,text,text,text,text,boolean) to authenticated;

do $migration$
declare definition text;needle text;
begin
 definition:=pg_get_functiondef('private.create_member_profile()'::regprocedure);
 needle:='   if ref<>'''' then';
 if strpos(definition,needle)=0 then raise exception 'Shopping signup referral hook missing';end if;
 execute replace(definition,needle,'   ref:=regexp_replace(ref,''^USR-'',''MIO-'');'||chr(10)||needle);
 -- The shared order implementation stays private. Public entry points decide whether
 -- a signed-in account or an affiliate-backed guest receipt authorizes placement.
 definition:=pg_get_functiondef('private.place_shopping_order_core(jsonb,text,text,text,text,text,text,text,text)'::regprocedure);
 needle:='if auth.uid() is null then raise exception ''Sign in first'';end if;';
 if strpos(definition,needle)=0 then raise exception 'Order implementation hook missing';end if;
 execute replace(definition,needle,'-- Authorization is enforced by the authenticated/affiliate-only public entry points.');
 definition:=pg_get_functiondef('public.place_shopping_order(jsonb,text,text,text,text,text,text,text)'::regprocedure);
 needle:=' placed:=private.place_shopping_order_core';
 if strpos(definition,needle)=0 then raise exception 'Authenticated referral hook missing';end if;
 execute replace(definition,needle,$hook$
 if code is not null then
  select member_code into code from public.member_profiles where user_id=private.resolve_shopping_referral(code);
  if code is null then raise exception 'User referral link is no longer valid';end if;
 end if;
 placed:=private.place_shopping_order_core$hook$);
 definition:=pg_get_functiondef('public.place_configured_bundle_order(uuid,uuid,jsonb,text,jsonb)'::regprocedure);
 needle:='  if member is null then raise exception ''Create or sign in to your User account before placing an order'';end if;';
 if strpos(definition,needle)=0 then raise exception 'Bundle guest hook missing';end if;
 execute replace(definition,needle,$hook$
  if member is null and (private.resolve_shopping_referral(p_request->>'p_affiliate_code') is null or coalesce(p_request->>'p_funding_method','SPONSOR')<>'SPONSOR') then
    raise exception 'Guest checkout needs a valid User referral and sponsor hold; advance payment requires an account';
  end if;$hook$);
end $migration$;

create or replace function public.place_guest_affiliate_order(p_items jsonb,p_shipping_name text,p_shipping_phone text,p_shipping_address text,p_shipping_city text,p_guest_email text,p_idempotency_key text,p_access_token text,p_affiliate_code text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare seller uuid;code text;placed jsonb;o public.orders%rowtype;requirement jsonb;
begin
 if auth.uid() is not null then raise exception 'Use your signed-in shopping account checkout';end if;
 seller:=private.resolve_shopping_referral(p_affiliate_code);
 if seller is null then raise exception 'Guest checkout requires a valid User referral link';end if;
 select member_code into code from public.member_profiles where user_id=seller;
 placed:=private.place_shopping_order_core(p_items,p_shipping_name,p_shipping_phone,p_shipping_address,p_shipping_city,p_guest_email,p_idempotency_key,p_access_token,code);
 select * into o from public.orders where id=(placed->>'order_id')::uuid for update;
 -- A retry never changes attribution, financial snapshots or an existing approved hold.
 if o.selling_affiliate_id is distinct from seller then raise exception 'Order reference belongs to a different referral';end if;
 requirement:=private.customer_order_requirement(o.total_pkr,o.usd_to_pkr_rate);
 update public.affiliate_guest_order_approvals set hold_mio=(requirement->>'hold_mio')::numeric,hold_amount=(requirement->>'hold_mio')::numeric,required_pkr=(requirement->>'required_pkr')::numeric,rate_snapshot=o.usd_to_pkr_rate
 where order_id=o.id and status in('pending','guarantee_requested');
 if o.status='placed' then update public.orders set cod_due_pkr=total_pkr where id=o.id;end if;
 return placed||requirement||jsonb_build_object('funding_method','SPONSOR','guest',true);
end $$;
revoke all on function public.place_guest_affiliate_order(jsonb,text,text,text,text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.place_guest_affiliate_order(jsonb,text,text,text,text,text,text,text,text) to anon,authenticated;

create or replace function public.guest_order_status(p_order_code text,p_access_token text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare o public.orders%rowtype;a public.affiliate_guest_order_approvals%rowtype;
begin
 if length(coalesce(p_access_token,''))<32 then raise exception 'Guest order access denied';end if;
 select * into o from public.orders where upper(order_code)=upper(trim(p_order_code)) and buyer_id is null and guest_access_token_hash=md5(p_access_token);
 if o.id is null then raise exception 'Guest order access denied';end if;
 select * into a from public.affiliate_guest_order_approvals where order_id=o.id;
 return jsonb_build_object('id',o.id,'order_code',o.order_code,'created_at',o.created_at,'status',o.status,'payment_status',o.payment_status,'payment_method',o.payment_method,
 'affiliate_attributed',o.selling_affiliate_id is not null,'sponsor_approval_status',a.status,'hold_mio',a.hold_mio,'required_pkr',a.required_pkr,
 'sponsor_confirmation',case when a.status in('approved','released','cancelled_refunded')then 'confirmed' when a.status='guarantee_requested'then 'awaiting sponsor guarantee' else a.status end,
 'admin_confirmation',case when o.payment_status='confirmed'or o.status in('confirmed','processing','shipped','delivered')then 'confirmed' else 'pending' end,
 'security_guarantee',a.hold_type,'total_pkr',o.total_pkr,'cod_due_pkr',o.cod_due_pkr,'shipping_name',o.shipping_name,'shipping_phone',o.shipping_phone,'shipping_address',o.shipping_address,'shipping_city',o.shipping_city,
 'items',coalesce((select jsonb_agg(jsonb_build_object('product_name_snapshot',i.product_name_snapshot,'quantity',i.quantity,'unit_price_pkr',i.unit_price_pkr,'line_total_pkr',i.line_total_pkr)order by i.created_at)from public.order_items i where i.order_id=o.id),'[]'::jsonb));
end $$;
notify pgrst,'reload schema';

-- Order-specific payment proof is private. A User cannot inspect another User's files.
alter table private.customer_order_funding add column proof_path text;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('customer-payment-proofs','customer-payment-proofs',false,5242880,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
create function private.shopping_proof_access(p_name text,p_upload boolean) returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and (
 (not p_upload and private.has_role('admin')) or
 (split_part(p_name,'/',1)=auth.uid()::text and exists(
 select 1 from private.customer_order_funding f join public.orders o on o.id=f.order_id
 where f.customer_id=auth.uid() and f.order_id::text=split_part(p_name,'/',2)
 and (not p_upload or (f.method='ADVANCE' and f.status in('awaiting_payment','rejected') and o.status='placed')))))
$$;
revoke all on function private.shopping_proof_access(text,boolean) from public,anon,authenticated;
grant execute on function private.shopping_proof_access(text,boolean) to authenticated;
create policy "customer proof uploads for own pending order" on storage.objects for insert to authenticated
with check(bucket_id='customer-payment-proofs' and private.shopping_proof_access(name,true));
create policy "customer proofs readable by owner and operations" on storage.objects for select to authenticated
using(bucket_id='customer-payment-proofs' and private.shopping_proof_access(name,false));
create function public.submit_shopping_advance_with_proof(p_order_id uuid,p_account_id uuid,p_transaction_id text,p_proof_path text)
returns void language plpgsql security definer set search_path='' as $$
declare f private.customer_order_funding%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 perform 1 from public.orders where id=p_order_id for update;
 select * into f from private.customer_order_funding where order_id=p_order_id for update;
 if f.customer_id is distinct from auth.uid() then raise exception 'Order not found';end if;
 if p_proof_path is null or split_part(p_proof_path,'/',1)<>auth.uid()::text or split_part(p_proof_path,'/',2)<>p_order_id::text or not exists(
 select 1 from storage.objects where bucket_id='customer-payment-proofs' and name=p_proof_path
 and metadata->>'mimetype' in('image/jpeg','image/png','image/webp') and (metadata->>'size')::numeric between 1 and 5242880
 ) then raise exception 'Upload a valid payment screenshot for this order';end if;
 if f.status='submitted' and f.proof_path is distinct from p_proof_path then raise exception 'Payment is already under review';end if;
 perform public.submit_shopping_advance(p_order_id,p_account_id,p_transaction_id);
 update private.customer_order_funding set proof_path=p_proof_path where order_id=p_order_id and status='submitted';
end $$;
revoke all on function public.submit_shopping_advance(uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.submit_shopping_advance_with_proof(uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.submit_shopping_advance_with_proof(uuid,uuid,text,text) to authenticated;

-- Receiving account explicitly supplied by the site owner for customer advances.
with added as (
 insert into private.customer_payment_accounts(bank_name,account_title,account_number,instructions,active)
 select 'Easypaisa','Abdul Rehman Abbasi','0302042932','Pay the exact advance shown for your order. Submit the transaction ID and a clear payment screenshot against the same order.',true
 where not exists(select 1 from private.customer_payment_accounts where lower(bank_name)='easypaisa' and account_number='0302042932')
 returning id
)
insert into public.audit_logs(action,entity_type,entity_id,after_data)
select 'CUSTOMER_PAYMENT_ACCOUNT_CONFIGURED','payment_account',id,jsonb_build_object('source','Site owner instruction','method','Easypaisa') from added;
notify pgrst,'reload schema';

create or replace function public.admin_shopping_payments() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 return jsonb_build_object('accounts',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at) from private.customer_payment_accounts a),'[]'),
 'summary',(select jsonb_build_object('submitted',count(*) filter(where status='submitted'),'refund_due',count(*) filter(where status='refund_due'),'pending_pkr',coalesce(sum(required_pkr) filter(where status='submitted'),0)) from private.customer_order_funding where method='ADVANCE'),
 'payments',coalesce((select jsonb_agg(x.data order by x.priority,x.created_at desc) from (select f.created_at,case f.status when 'submitted' then 0 when 'refund_due' then 1 else 2 end as priority,to_jsonb(f)||jsonb_build_object('order_code',o.order_code,'total_pkr',o.total_pkr,'cod_due_pkr',o.cod_due_pkr,'customer_name',o.shipping_name,'order_status',o.status) as data from private.customer_order_funding f join public.orders o on o.id=f.order_id where f.method='ADVANCE' order by priority,f.created_at desc limit 100) x),'[]'));
end $$;
notify pgrst,'reload schema';
