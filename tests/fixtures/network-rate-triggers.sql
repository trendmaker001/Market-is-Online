CREATE OR REPLACE FUNCTION private.current_mio_reference_price()
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select coalesce((select (config_value#>>'{}')::numeric from public.system_config
  where config_key='MIO_REFERENCE_PRICE_PKR' and effective_to is null order by version desc limit 1),300)::numeric
$function$;