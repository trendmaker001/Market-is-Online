CREATE OR REPLACE FUNCTION private.enforce_shopping_ppv_mode()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  is_locked boolean;
begin
  if new.point_type = 'PPV' and new.source_order_id is not null and new.amount > 0 then
    select s.locked into is_locked from private.shopping_ppv_cap_status(new.member_id) s;
    if is_locked then
      update public.member_profiles
      set shopping_reward_mode = 'MIO', updated_at = now()
      where user_id = new.member_id and shopping_reward_mode <> 'MIO';
    end if;
  end if;
  return new;
end
$function$
;
