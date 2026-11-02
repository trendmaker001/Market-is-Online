-- Cover manager-program foreign keys used by distribution, audit and support queries.
create index if not exists manager_bonus_cycles_distributed_by_idx on public.manager_bonus_cycles(distributed_by);
create index if not exists manager_bonus_distributions_bonus_idx on public.manager_bonus_distributions(bonus_transaction_id);
create index if not exists manager_bonus_distributions_member_idx on public.manager_bonus_distributions(member_id,created_at desc);
create index if not exists manager_point_ledger_source_member_idx on public.manager_point_ledger(source_member_id,created_at desc);
create index if not exists manager_point_ledger_source_point_idx on public.manager_point_ledger(source_point_id);
create index if not exists member_rank_history_rank_idx on public.member_rank_history(rank_code);
create index if not exists mio_ledger_manager_distribution_idx on public.mio_ledger(manager_distribution_id) where manager_distribution_id is not null;
