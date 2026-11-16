-- Verified against the hosted schema and current table sizes; bounded lock waits.
set local lock_timeout = '3s';
set local statement_timeout = '30s';
create index if not exists customer_identities_sponsor_id_idx on private.customer_identities (sponsor_id);
create index if not exists customer_order_funding_reviewer_id_idx on private.customer_order_funding (reviewer_id);
create index if not exists member_admin_baselines_activation_id_idx on private.member_admin_baselines (activation_id);
create index if not exists member_admin_changes_actor_id_idx on private.member_admin_changes (actor_id);
create index if not exists member_admin_changes_member_id_idx on private.member_admin_changes (member_id);
create index if not exists member_placement_intents_placement_anchor_idx on private.member_placement_intents (placement_anchor);
create index if not exists member_placement_intents_sponsor_id_idx on private.member_placement_intents (sponsor_id);
create index if not exists member_provisioning_actor_id_idx on private.member_provisioning (actor_id);
create index if not exists member_provisioning_placement_id_idx on private.member_provisioning (placement_id);
create index if not exists member_provisioning_sponsor_id_idx on private.member_provisioning (sponsor_id);
create index if not exists monthly_maintenance_countries_updated_by_idx on private.monthly_maintenance_countries (updated_by);
create index if not exists shopping_membership_requests_admin_reviewed_by_idx on private.shopping_membership_requests (admin_reviewed_by);
create index if not exists shopping_membership_requests_reviewed_by_idx on private.shopping_membership_requests (reviewed_by);
create index if not exists transaction_authorizations_member_id_idx on private.transaction_authorizations (member_id);
create index if not exists vendor_identities_introduced_by_idx on private.vendor_identities (introduced_by);
create index if not exists maintenance_generation_payouts_beneficiary_id_idx on public.maintenance_generation_payouts (beneficiary_id);
create index if not exists maintenance_wallet_ledger_member_id_idx on public.maintenance_wallet_ledger (member_id);
create index if not exists maintenance_wallet_ledger_order_id_idx on public.maintenance_wallet_ledger (order_id);
create index if not exists point_ledger_admin_change_id_idx on public.point_ledger (admin_change_id);
create index if not exists product_commission_proposals_reviewed_by_idx on public.product_commission_proposals (reviewed_by);
create index if not exists product_commission_proposals_submitted_by_idx on public.product_commission_proposals (submitted_by);

