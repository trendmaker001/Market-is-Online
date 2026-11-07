CREATE OR REPLACE FUNCTION private.route_bonus_to_income_wallet()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s jsonb;k text;t text;inserted integer;begin
 if new.status<>'posted' or new.payable_amount<=0 then return new;end if;
 if tg_op='UPDATE' and old.status='posted' then return new;end if;
 s:=private.current_bonus_wallet_routing();k:=private.network_bonus_wallet_route_key(new.method,new.calculation_trace);t:=coalesce(s->'routes'->>k,'proceed');
 insert into public.member_income_wallets(member_id)values(new.beneficiary_id)on conflict do nothing;
 insert into public.income_wallet_ledger(member_id,wallet_kind,amount,entry_kind,source_bonus_id,note,metadata,idempotency_key)
 values(new.beneficiary_id,t,new.payable_amount,'network_earning',new.id,case when t='cash' then 'Network earning routed to Cash Wallet' else 'Network earning routed to Proceed Wallet' end,jsonb_build_object('method',new.method,'generation',new.generation,'routing_key',k,'routing_version',s->>'version','target_wallet',t),'bonus-route:'||new.id)
 on conflict(idempotency_key)do nothing;get diagnostics inserted=row_count;
 if inserted=1 and t='proceed' then
  update public.mio_wallet_accounts set balance=balance-new.payable_amount,updated_at=now() where member_id=new.beneficiary_id and balance>=new.payable_amount;
  if not found then raise exception 'Cash wallet routing reconciliation failed';end if;
  update public.member_income_wallets set proceed_mio=proceed_mio+new.payable_amount,updated_at=now() where member_id=new.beneficiary_id;
 end if;return new;
end$function$
