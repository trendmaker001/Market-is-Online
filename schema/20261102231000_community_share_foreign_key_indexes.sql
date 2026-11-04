-- Cover Community Share foreign keys used by audit and admin lookups.
create index if not exists community_fund_contributions_created_by_idx
 on public.community_fund_contributions(created_by);
create index if not exists community_share_cycles_distributed_by_idx
 on public.community_share_cycles(distributed_by);
create index if not exists community_share_distributions_bonus_idx
 on public.community_share_distributions(bonus_transaction_id);
create index if not exists mio_ledger_community_distribution_idx
 on public.mio_ledger(community_distribution_id);
