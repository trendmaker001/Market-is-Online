lock table private.marketplace_bundle_types in share row exclusive mode;

update private.marketplace_bundle_types
set required_units = 9, ppv_divider = 6,
    max_per_product = case when max_per_product > 9 then 9 else max_per_product end
where name = 'Bundle 4' and display_order = 4;

update private.marketplace_bundle_types
set required_units = 12, ppv_divider = 7, status = 'enabled',
    max_per_product = case when max_per_product > 12 then 12 else max_per_product end
where name = 'Bundle 5' and display_order = 5;

insert into private.marketplace_bundle_types(name, required_units, ppv_divider, status)
select 'Bundle 6', 15, 8, 'enabled'
where not exists (select 1 from private.marketplace_bundle_types where name = 'Bundle 6');
