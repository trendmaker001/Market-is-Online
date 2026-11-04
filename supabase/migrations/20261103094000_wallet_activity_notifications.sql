-- Feed future Cash Wallet and checkout ledger movements into the member notification centre.
create or replace function private.notify_mio_ledger_entry() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 perform private.notify_member(new.member_id,case when new.amount>0 then 'income' else 'outgoing' end,
  case when new.amount>0 then 'Cash Wallet credited' else 'Cash Wallet deducted' end,
  coalesce(new.reason,replace(new.action,'_',' ')),'mio_ledger',new.id,
  jsonb_build_object('amount',new.amount,'action',new.action));
 return new;
end$$;
create trigger zz_notify_mio_ledger_entry after insert on public.mio_ledger
 for each row execute function private.notify_mio_ledger_entry();

create or replace function private.notify_order_payment_entry() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 perform private.notify_member(new.member_id,
  case when new.entry_kind in('checkout_refund','guarantee_refund') then 'refund' when new.wallet_kind='shopping' then 'shopping' else 'wallet' end,
  case when new.entry_kind in('checkout_refund','guarantee_refund') then 'Order wallet refund' when new.wallet_kind='shopping' then 'Shopping Points used' else 'Cash Wallet order activity' end,
  new.note,'order',new.order_id,jsonb_build_object('wallet',new.wallet_kind,'amount',new.amount,'entry_kind',new.entry_kind));
 return new;
end$$;
create trigger zz_notify_order_payment_entry after insert on public.order_payment_ledger
 for each row execute function private.notify_order_payment_entry();

revoke all on function private.notify_mio_ledger_entry(),private.notify_order_payment_entry() from public,anon,authenticated;
