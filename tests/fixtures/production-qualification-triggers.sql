CREATE OR REPLACE FUNCTION private.refresh_binary_qualification_from_dp()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if new.point_type='DP' and new.entry_kind='credit' then
  perform private.refresh_binary_qualification_ancestors(new.member_id);
 end if;
 return new;
end;
$function$
;
CREATE OR REPLACE FUNCTION private.refresh_binary_qualification_from_placement()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 perform private.refresh_binary_qualification_ancestors(new.member_id);
 return new;
end;
$function$
;
