-- Compatibility endpoint. Install wallet_history.sql first; both endpoints use
-- the same historical-routing-aware statement and never write balances.
create or replace function public.my_cash_wallet_history(p_filter text default 'all',p_page integer default 1,p_limit integer default 20)
returns jsonb language sql stable security definer set search_path='' as $$
 select private.wallet_history_for_member(auth.uid(),'cash',p_filter,null,null,p_page,p_limit);
$$;
revoke all on function public.my_cash_wallet_history(text,integer,integer) from public,anon;
grant execute on function public.my_cash_wallet_history(text,integer,integer) to authenticated;
