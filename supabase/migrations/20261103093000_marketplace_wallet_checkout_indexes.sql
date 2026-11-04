-- Cover foreign keys introduced by wallet checkout for predictable joins/deletes.
create index if not exists member_cod_guarantees_buyer_idx on public.member_cod_guarantees(buyer_id);
create index if not exists member_cod_guarantees_payer_idx on public.member_cod_guarantees(payer_id) where payer_id is not null;
create index if not exists promotion_rank_releases_rank_idx on public.promotion_rank_releases(rank_code);
