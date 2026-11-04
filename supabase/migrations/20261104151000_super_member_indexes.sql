-- Cover the Super Member suspension audit foreign key for admin reporting.
create index if not exists super_member_qualifications_suspended_by_idx
  on private.super_member_qualifications(suspended_by)
  where suspended_by is not null;
