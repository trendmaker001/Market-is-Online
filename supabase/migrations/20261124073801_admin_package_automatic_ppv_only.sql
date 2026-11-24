-- Preserve the live admin function, including its authorization, locks and audits.
-- Only changed package assignments gain the missing non-shopping PPV entitlement.
do $migration$
declare fn text; anchor text:=$anchor$   update private.member_admin_baselines set package_assigned=true,package_code=nullif(p_values->>'package_code',''),package_assigned_at=now(),activation_id=activation where member_id=p_member;$anchor$;
begin
 select pg_get_functiondef('private.admin_save_member_state(uuid,text,jsonb,jsonb,uuid,text)'::regprocedure) into fn;
 if position('admin-package-ppv:' in fn)>0 then return;end if;
 if (length(fn)-length(replace(fn,anchor,'')))/length(anchor)<>1 then
  raise exception 'Admin package function changed; review before applying PPV patch';
 end if;
 execute replace(fn,anchor,anchor||E'\n'||$patch$   -- Admin entitlement grants PPV only, under the existing member lock/restore context.
   -- Shopping/order PPV remains additional; prior package and manual PPV count toward
   -- the entitlement so upgrades and remove/reassign cycles cannot duplicate it.
   if nullif(p_values->>'package_code','') is not null then
    select coalesce(sum(pl.amount),0) into current_amount
    from public.point_ledger pl
    where pl.member_id=p_member and pl.point_type='PPV'
      and pl.source_order_id is null and pl.created_at>private.financial_reset_at();
    delta:=greatest(plan.ppv-greatest(current_amount,0),0);
    if delta>0 then
     insert into public.point_ledger(member_id,point_type,amount,entry_kind,admin_change_id,idempotency_key)
     values(p_member,'PPV',delta,'credit',change_id,'admin-package-ppv:'||change_id);
    end if;
   end if;$patch$);
end
$migration$;
