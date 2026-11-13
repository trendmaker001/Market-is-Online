begin;
-- Seller proposals are separate from approved economics and historical orders.
create table public.product_commission_proposals (
 product_id uuid primary key references public.products(id) on delete cascade,
 requested_rate numeric check(requested_rate between 0 and 1 and requested_rate=round(requested_rate,6)),
 status text not null default 'pending' check(status in ('pending','reviewed')),
 submitted_by uuid not null references auth.users(id),
 submitted_at timestamptz not null default clock_timestamp(),
 approved_rate numeric check(approved_rate between 0 and 1),
 reviewed_by uuid references auth.users(id),
 reviewed_at timestamptz
);
alter table public.product_commission_proposals enable row level security;
revoke all on public.product_commission_proposals from public,anon,authenticated;
grant select on public.product_commission_proposals to authenticated;
grant all on public.product_commission_proposals to service_role;
create policy "Seller and admin read product percentage proposals" on public.product_commission_proposals
 for select to authenticated using (
 (select public.current_user_is_admin()) or exists (
 select 1 from public.products p join public.vendors v on v.id=p.vendor_id
 where p.id=product_id and v.owner_user_id=(select auth.uid())));
create or replace function public.save_product_listing_with_commission(
 p_country text,p_product_id uuid,p_vendor_id uuid,p_name text,p_sku text,p_description text,
 p_category text,p_price numeric,p_stock integer,p_images jsonb,p_submit boolean,p_commission numeric
) returns uuid language plpgsql security definer set search_path='' as $$
declare pid uuid; vendor_rate numeric; old_proposal jsonb;
begin
 if auth.uid() is null then raise exception 'Active seller access required'; end if;
 select commission_rate into vendor_rate from public.vendors where id=p_vendor_id and status='active'
 and (owner_user_id=auth.uid() or private.has_role('admin'));
 if not found then raise exception 'Active seller access required';end if;
 if p_commission is not null and (p_commission<0 or p_commission>1 or p_commission<>round(p_commission,6)) then
 raise exception 'Enter a product percentage between 0 and 100, with up to 4 decimal places';end if;
 if p_product_id is not null then
  perform 1 from public.products where id=p_product_id and vendor_id=p_vendor_id and bundle_definition is null for update;
  if not found then raise exception 'Product not found or use the bundle builder';end if;
  select to_jsonb(c) into old_proposal from public.product_commission_proposals c where product_id=p_product_id;
 end if;
 -- Reuse the established fees and PPV budget validation; never activate seller proposals here.
 perform private.product_economics(p_price,p_price,coalesce(p_commission,vendor_rate),private.current_mio_reference_price(),null,'reserve');
 pid:=public.save_product_listing_country(p_country,p_product_id,p_vendor_id,p_name,p_sku,p_description,p_category,p_price,p_stock,p_images,p_submit);
 insert into public.product_commission_proposals(product_id,requested_rate,status,submitted_by,submitted_at)
 values(pid,p_commission,'pending',auth.uid(),clock_timestamp())
 on conflict(product_id) do update set requested_rate=excluded.requested_rate,status='pending',submitted_by=excluded.submitted_by,
 submitted_at=excluded.submitted_at,approved_rate=null,reviewed_by=null,reviewed_at=null;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data)
 values(auth.uid(),'PRODUCT_COMMISSION_PROPOSED','product',pid,old_proposal,jsonb_build_object('requested_rate',p_commission,'uses_vendor_default',p_commission is null));
 return pid;
end $$;
revoke all on function public.save_product_listing_with_commission(text,uuid,uuid,text,text,text,text,numeric,integer,jsonb,boolean,numeric) from public,anon;
grant execute on function public.save_product_listing_with_commission(text,uuid,uuid,text,text,text,text,numeric,integer,jsonb,boolean,numeric) to authenticated;

CREATE OR REPLACE FUNCTION public.admin_save_product_economics(p_product uuid, p_sale numeric, p_compare numeric, p_commission numeric, p_ppv numeric, p_remainder text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare before_row public.products%rowtype;after_row public.products%rowtype;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 if p_sale is null or p_sale<>round(p_sale,2) or (p_compare is not null and (p_compare<p_sale or p_compare<>round(p_compare,2))) or (p_commission is not null and (p_commission<0 or p_commission>1 or p_commission<>round(p_commission,6))) or p_remainder not in ('reserve','discount') then raise exception 'Enter valid pricing, commission and remainder settings';end if;
 select * into before_row from public.products where id=p_product for update;
 if not found then raise exception 'Product not found';end if;
 if before_row.bundle_definition is not null then raise exception 'Use the bundle builder to edit bundle pricing';end if;
 update public.products set price_pkr=p_sale,compare_at_price_pkr=p_compare,commission_rate_override=p_commission,assigned_ppv=p_ppv,ppv_remainder_policy=p_remainder,reward_discount_pkr=0,awarded_rate_override=null,updated_at=now() where id=p_product returning * into after_row;
 update public.product_commission_proposals set status='reviewed',approved_rate=p_commission,reviewed_by=auth.uid(),reviewed_at=now() where product_id=p_product;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data) values(auth.uid(),'PRODUCT_ECONOMICS_UPDATED','product',p_product,to_jsonb(before_row),to_jsonb(after_row));
 return jsonb_build_object('product_id',p_product,'maximum_ppv',after_row.maximum_ppv,'assigned_ppv',after_row.ppv_per_unit,'sale_price',after_row.price_pkr,'reward_discount',after_row.reward_discount_pkr);
end $function$
;
CREATE OR REPLACE FUNCTION public.admin_review_product(p_product_id uuid, p_approve boolean, p_ppv numeric DEFAULT NULL::numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$ begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if p_approve and exists(select 1 from public.product_commission_proposals where product_id=p_product_id and status='pending') then raise exception 'Review the product percentage before approval'; end if;
 if p_approve and (p_ppv is null or p_ppv<0 or p_ppv>1000000 or p_ppv<>round(p_ppv,4)) then raise exception 'Assign PPV to this product before approval'; end if;
 if p_approve and exists(select 1 from public.products where id=p_product_id and (price_pkr<=0 or stock_quantity<=0 or nullif(image_url,'') is null)) then raise exception 'Enter positive PKR price, available stock and a product photo before approval'; end if;
 update public.products set status=case when p_approve then 'approved'::public.product_status else 'rejected'::public.product_status end,ppv_per_unit=case when p_approve then p_ppv else ppv_per_unit end,updated_at=now() where id=p_product_id and status in('draft','pending','rejected','archived');
 if not found then raise exception 'Reviewable product not found'; end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'PRODUCT_PPV_REVIEWED','product',p_product_id,jsonb_build_object('approved',p_approve,'ppv_per_unit',p_ppv));
end $function$
;

-- Approve the exact reviewed price/percentage/PPV together in one transaction.
create or replace function public.admin_approve_product_with_economics(
 p_product uuid,p_sale numeric,p_compare numeric,p_commission numeric,p_ppv numeric,p_remainder text,p_submission timestamptz
) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; submission timestamptz; actual_ppv numeric;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 perform 1 from public.products where id=p_product and bundle_definition is null and status in ('draft','pending','rejected','archived') for update;
 if not found then raise exception 'Reviewable product not found';end if;
 select submitted_at into submission from public.product_commission_proposals where product_id=p_product for update;
 if submission is distinct from p_submission then raise exception 'The seller updated this listing. Refresh and review the latest percentage';end if;
 result:=public.admin_save_product_economics(p_product,p_sale,p_compare,p_commission,p_ppv,p_remainder);
 select ppv_per_unit into actual_ppv from public.products where id=p_product;
 perform public.admin_review_product(p_product,true,actual_ppv);
 return result||jsonb_build_object('status','approved');
end $$;
revoke all on function public.admin_approve_product_with_economics(uuid,numeric,numeric,numeric,numeric,text,timestamptz) from public,anon;
grant execute on function public.admin_approve_product_with_economics(uuid,numeric,numeric,numeric,numeric,text,timestamptz) to authenticated;
commit;
