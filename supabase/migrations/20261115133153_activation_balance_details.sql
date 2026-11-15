-- Keep the existing payment, PIN, upgrade and reward logic unchanged.
-- Report exact numeric values instead of a misleading generic shortfall.
do $migration$
declare
  definition text := pg_get_functiondef('public.activate_package_with_mio(text,text,text)'::regprocedure);
  old_clause text := $old$if new_balance is null then raise exception 'Insufficient MIO Points';end if;$old$;
  new_clause text := $new$if new_balance is null then
  select coalesce(balance,0) into new_balance from public.mio_wallet_accounts where member_id=member;
  new_balance:=coalesce(new_balance,0);
  raise exception 'Insufficient MIO Points. Required: % MIO. Available in Cash Wallet: % MIO. Shortfall: % MIO.',due_payable,new_balance,greatest(due_payable-new_balance,0);
 end if;$new$;
begin
  if strpos(definition,old_clause)=0 then
    raise exception 'Expected activation balance check was not found; review before updating';
  end if;
  execute replace(definition,old_clause,new_clause);
end $migration$;
