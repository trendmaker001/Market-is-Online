-- Cover the sponsor guarantee holder foreign key as guest approvals grow.
create index if not exists affiliate_guest_approvals_hold_member_idx
  on public.affiliate_guest_order_approvals(hold_member_id);
