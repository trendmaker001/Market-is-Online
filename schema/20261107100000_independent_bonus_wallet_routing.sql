-- Independent destinations for future bonuses. Existing earnings and balances are unchanged.
create or replace function private.default_bonus_wallet_routes()
returns jsonb language sql immutable set search_path='' as $$
select jsonb_build_object('direct_sponsor','cash','welcome_bonus','cash','generation','proceed',
'binary_placement','proceed','binary_pool_share','proceed','team_manager','proceed','community_share','proceed',
'ecommerce_cashback','cash','ecommerce_affiliate_level1','cash','ecommerce_level2','proceed','vendor_introducer','proceed')
$$;
create or replace function private.network_bonus_wallet_route_key(p_method public.bonus_method,p_trace jsonb)
returns text language sql immutable set search_path='' as $$
select case
when p_method='direct' and coalesce(p_trace->>'bonus_component','')='welcome_bonus' then 'welcome_bonus'
when p_method='direct' then 'direct_sponsor'
when p_method='generation' then 'generation'
when p_method='team_manager' then 'team_manager'
when p_method='community_share' then 'community_share'
when p_method='single_line' then 'binary_placement'
when p_method='binary_pool_share' then 'binary_pool_share'
else 'generation' end
$$;
create or replace function public.admin_set_bonus_wallet_routing(p_routes jsonb,p_expected_version integer)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
 v_keys text[]:=array['direct_sponsor','welcome_bonus','generation','binary_placement',
 'binary_pool_share','team_manager','community_share','ecommerce_cashback','ecommerce_affiliate_level1',
 'ecommerce_level2','vendor_introducer'];
 v_key text;v_current_version integer:=0;v_current_routes jsonb;v_new_version integer;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 if p_routes is null or jsonb_typeof(p_routes)<>'object' then raise exception 'A complete wallet routing object is required';end if;
 foreach v_key in array v_keys loop
  if coalesce(p_routes->>v_key,'') not in('cash','proceed') then
   raise exception 'Choose Cash Wallet or Proceed Wallet for %',v_key;
  end if;
 end loop;
 if exists(select 1 from jsonb_object_keys(p_routes) supplied(key) where not(supplied.key=any(v_keys))) then
  raise exception 'Unknown bonus wallet routing key';
 end if;
 perform pg_advisory_xact_lock(hashtextextended('BONUS_WALLET_ROUTING',0));
 select version,config_value into v_current_version,v_current_routes
 from public.system_config where config_key='BONUS_WALLET_ROUTING' and effective_to is null
 order by version desc limit 1;
 v_current_version:=coalesce(v_current_version,0);
 if p_expected_version is null or p_expected_version<>v_current_version then
  raise exception 'Wallet routing was updated by another session. Refresh and try again.';
 end if;
 v_new_version:=v_current_version+1;
 update public.system_config set effective_to=now()
 where config_key='BONUS_WALLET_ROUTING' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,effective_to,created_by)
 values('BONUS_WALLET_ROUTING',v_new_version,p_routes,now(),null,auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,before_data,after_data)
 values(auth.uid(),'BONUS_WALLET_ROUTING_UPDATED','system_config',
 jsonb_build_object('version',v_current_version,'routes',v_current_routes),
 jsonb_build_object('version',v_new_version,'routes',p_routes));
 return private.current_bonus_wallet_routing();
end $function$;

