create table private.marketplace_score_origin (
 singleton boolean primary key check(singleton),
 accounts bigint not null
);
revoke all on private.marketplace_score_origin from public, anon, authenticated;
insert into private.marketplace_score_origin
select true, count(*) from auth.users where not coalesce(is_anonymous,false) and deleted_at is null;

create function public.marketplace_community_score() returns bigint
language sql stable security definer set search_path='' as $$
 with current_total as (
   select count(*) as n from auth.users where not coalesce(is_anonymous,false) and deleted_at is null
 )
 select 1000 + accounts + 7*(n-accounts) + (n/2 - accounts/2)
 from private.marketplace_score_origin cross join current_total where singleton
$$;
revoke all on function public.marketplace_community_score() from public;
grant execute on function public.marketplace_community_score() to anon, authenticated;
