create or replace function public.lookup_mio_transfer_receipt(p_transfer_id uuid)
returns table(transfer_id uuid,created_at timestamptz,amount numeric,sender_id uuid,sender_name text,sender_code text,recipient_id uuid,recipient_name text,recipient_code text,reason text)
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in required';end if;
 if exists(select 1 from private.exchange_transfers where id=p_transfer_id) then
  if not exists(select 1 from private.exchange_transfers t where t.id=p_transfer_id and auth.uid() in(t.actor_id,t.recipient_id)) then raise exception 'Transfer not found for this account';end if;
  return query select t.id,t.created_at,t.amount,s.user_id,s.full_name,s.member_code,r.user_id,r.full_name,r.member_code,
   case when t.kind='fund' then 'Cash Wallet to own Exchange Wallet' else initcap(t.source_wallet)||' Wallet to '||initcap(t.destination_wallet)||' Wallet' end||case when t.note<>'' then ' · '||t.note else '' end
  from private.exchange_transfers t join public.member_profiles s on s.user_id=t.actor_id join public.member_profiles r on r.user_id=t.recipient_id where t.id=p_transfer_id;
  return;
 end if;
 if not exists(select 1 from public.mio_ledger l where l.transfer_id=p_transfer_id and l.member_id=auth.uid() and l.action in ('transfer_in','transfer_out')) then raise exception 'Transfer not found for this account';end if;
 return query select o.transfer_id,o.created_at,abs(o.amount),s.user_id,s.full_name,s.member_code,r.user_id,r.full_name,r.member_code,coalesce(o.reason,i.reason)
 from public.mio_ledger o join public.mio_ledger i on i.transfer_id=o.transfer_id and i.action='transfer_in' join public.member_profiles s on s.user_id=o.member_id join public.member_profiles r on r.user_id=i.member_id where o.transfer_id=p_transfer_id and o.action='transfer_out';
end $$;
revoke all on function public.lookup_mio_transfer_receipt(uuid) from public,anon;
grant execute on function public.lookup_mio_transfer_receipt(uuid) to authenticated;
