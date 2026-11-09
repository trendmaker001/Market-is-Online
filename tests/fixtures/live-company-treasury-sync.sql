CREATE OR REPLACE FUNCTION private.sync_company_treasury()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare company uuid;r record;delta numeric;target numeric;
begin
 select company_id into company from private.network_foundation where singleton;
 if company is null then return;end if;
 perform pg_advisory_xact_lock(hashtextextended('company-treasury-sync',0));
 for r in
  with expected as(select source_type,source_id,category,currency,sum(amount) amount from private.company_treasury_sources() group by 1,2,3,4)
  select coalesce(e.source_type,p.source_type) typ,coalesce(e.source_id,p.source_id) sid,
   coalesce(e.category,p.category) cat,coalesce(e.currency,p.currency) cur,
   coalesce(e.amount,0) target,coalesce(p.amount,0) previous
  from expected e full join public.company_treasury_positions p using(source_type,source_id,category,currency)
 loop
  target:=round(r.target,4);delta:=round(target-r.previous,4);
  if delta is null or abs(delta)<.0001 then continue;end if;
  insert into public.company_treasury_positions(source_type,source_id,category,currency,amount)
  values(r.typ,r.sid,r.cat,r.cur,target)
  on conflict(source_type,source_id,category,currency) do update set amount=excluded.amount,updated_at=now();
  insert into public.company_treasury_ledger(company_id,source_type,source_id,category,currency,amount)
  values(company,r.typ,r.sid,r.cat,r.cur,delta);
 end loop;
end
$function$

;
