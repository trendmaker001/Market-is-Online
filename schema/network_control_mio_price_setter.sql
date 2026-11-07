create or replace function public.admin_set_mio_reference_price(p_price numeric)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v integer;old_price numeric;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 if p_price is null or p_price<=0 or p_price>1000000 or p_price<>round(p_price,2) then raise exception 'Enter a price greater than zero with up to two decimal places';end if;
 perform pg_advisory_xact_lock(hashtextextended('mio-reference-price-pkr',0));
 old_price:=private.current_mio_reference_price();
 if p_price=old_price then return jsonb_build_object('price_pkr',old_price,'unchanged',true);end if;
 select coalesce(max(version),0)+1 into v from public.system_config where config_key='MIO_REFERENCE_PRICE_PKR';
 update public.system_config set effective_to=clock_timestamp() where config_key='MIO_REFERENCE_PRICE_PKR' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,created_by)
 values('MIO_REFERENCE_PRICE_PKR',v,to_jsonb(p_price),clock_timestamp(),auth.uid());
 -- Product trigger recalculates current catalog PPV. No order or ledger snapshot is updated.
 update public.products set ppv_per_unit=ppv_per_unit where vendor_submitted_price_pkr>0 and status<>'archived';
 insert into public.audit_logs(actor_id,action,entity_type,before_data,after_data)
 values(auth.uid(),'MIO_REFERENCE_PRICE_SET','system_config',jsonb_build_object('price_pkr',old_price),jsonb_build_object('price_pkr',p_price,'version',v));
 return jsonb_build_object('price_pkr',p_price,'version',v);
end $$;
revoke all on function public.admin_set_mio_reference_price(numeric) from public,anon;
grant execute on function public.admin_set_mio_reference_price(numeric) to authenticated;
