CREATE OR REPLACE FUNCTION private.validate_signup_gender()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 -- Shopping identity has its own name, phone and consent validation; gender is not a checkout requirement.
 if new.raw_user_meta_data->>'registration_type'='customer' then return new;end if;
 if new.raw_app_meta_data->>'provider'='email' and coalesce(new.raw_user_meta_data->>'gender','') not in ('male','female') then raise exception 'Select Male or Female';end if;
 return new;
end$function$
;
