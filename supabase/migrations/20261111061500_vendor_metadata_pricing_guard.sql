begin;
-- Ownership/contact edits do not change the agreement or reward budget.
-- Keep the existing pricing validation for financial edits.
create or replace function private.guard_vendor_award() returns trigger
language plpgsql security definer set search_path='' as $$
declare min_budget numeric;
begin
 if tg_op='UPDATE' and new.commission_rate is not distinct from old.commission_rate and new.awarded_rate is not distinct from old.awarded_rate then return new;end if;
 if new.commission_rate is null or new.commission_rate<.05 or new.commission_rate>1 then raise exception 'Agreement percentage is required and must cover company 5 percent';end if;
 if exists(select 1 from public.products where vendor_id=new.id and coalesce(vendor_submitted_price_pkr,0)<=0) then raise exception 'Set a positive submitted price on all store products before changing its agreement';end if;
 select min(new.commission_rate-.05-greatest(vendor_submitted_price_pkr-price_pkr,0)/vendor_submitted_price_pkr) into min_budget from public.products where vendor_id=new.id;
 if new.awarded_rate is not null and new.awarded_rate>coalesce(min_budget,new.commission_rate-.05) then raise exception 'Vendor reward percentage exceeds a product budget after discount';end if;
 if exists(select 1 from public.products where vendor_id=new.id and awarded_rate_override>new.commission_rate-.05-greatest(vendor_submitted_price_pkr-price_pkr,0)/vendor_submitted_price_pkr) then raise exception 'Reduce product overrides before reducing the vendor agreement';end if;return new;
end $$;
commit;
