-- Calendar filters and future display codes use UTC. Stored instants and historical records are unchanged.
do $migration$
declare signature text; definition text;
begin
 foreach signature in array array[
  'my_exchange_wallet(integer,text,integer,integer)',
  'admin_distribute_binary_pool(numeric)',
  'private.wallet_history_for_member(uuid,text,text,date,date,integer,integer)',
  'admin_proceed_fee_history(date,date,integer,integer)',
  'admin_binary_pool_dashboard()',
  'my_vendor_report(date,date,uuid,integer)'
 ] loop
  if to_regprocedure(signature) is null then raise exception 'Missing reporting function: %',signature;end if;
  definition:=pg_get_functiondef(to_regprocedure(signature));
  if strpos(definition,'Asia/Karachi')=0 then raise exception 'Expected calendar timezone missing: %',signature;end if;
  execute replace(definition,'Asia/Karachi','UTC');
 end loop;
end $migration$;
