CREATE OR REPLACE FUNCTION private.current_package_code(p_member_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select case when b.package_assigned then coalesce((select a.package_code from public.package_activations a where a.member_id=p_member_id and a.status='approved' and a.id is distinct from b.activation_id and coalesce(a.activated_at,a.requested_at)>b.package_assigned_at order by a.base_value desc,a.activated_at desc limit 1),b.package_code)
 else (select a.package_code from public.package_activations a where a.member_id=p_member_id and a.status='approved' order by a.base_value desc,a.activated_at desc nulls last,a.requested_at desc limit 1) end
 from (select 1) dummy left join private.member_admin_baselines b on b.member_id=p_member_id
$function$;

CREATE OR REPLACE FUNCTION private.enforce_package_membership()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN if private.member_restore_active(new.user_id) then return new;end if;
  if new.sponsor_id is not null
     and (tg_op = 'INSERT' or new.sponsor_id is distinct from old.sponsor_id)
     and not private.package_eligible(new.sponsor_id)
     and not exists (select 1 from public.user_roles where user_id = new.sponsor_id and role = 'admin') then
    raise exception 'This referral is locked. The sponsor must activate a plan before building a team';
  end if;
  if new.status = 'active'
     and not exists (select 1 from public.user_roles where user_id = new.user_id and role = 'admin')
     and not exists (select 1 from public.package_activations where member_id = new.user_id and status = 'approved') then
    new.status := 'inactive';
  end if;
  return new;
end;
$function$;
