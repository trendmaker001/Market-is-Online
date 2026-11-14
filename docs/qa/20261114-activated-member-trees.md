# Activated member trees and vendor identity — 2026-11-14

Scope: paid-only Generation/Binary/Binary Placement, deferred binary placement, immutable signup side, vendor root identity and direct vendor completeness, Pakistan flag images, Generation label, qualification chevrons.

## Database

Applied migration `20261114181236_activated_member_trees_and_vendor_identity.sql` to the existing production project. One unambiguous free placement was audited and removed; its single paid child was reconnected to the former parent on the same side. Paid descendant order and sponsor relationships are retained. No free placements remain. The free account's LEFT intent is saved for activation at the then-current branch bottom. Existing guards already rejected free sponsors; onboarding now includes an explicit check as defense in depth.

A private RLS-protected placement-intent table records side once, with no client grants. Direct binary inserts reject unactivated members. Admin-created free accounts save intent and defer actual placement. Existing conversion notifications now describe deferred placement accurately.

Vendor-only owners no longer require member profiles in the vendor join. All three direct vendors are included at depth 1. Root photo/join date and vendor country survive the wrappers.

Generation display filtering preserves underlying sponsor relationships and original depth. Binary ancestry is repaired in storage, rather than concealed with a blank display position.

## Preservation evidence

Read-only before/after fingerprints matched for all six groups:
- config: `612488c87ec3c50313b0d63a6519166f`
- points: `79804b0374162b6c7dd90b84fa8836e8`
- balances: `4adab187d1c0b3093eb919b9433a1369`
- earnings: `88ceb42f0be697c51bd2511b0e8a3cbe`
- formulas: `aea89f7c87fd432f168beb78e094ea11`
- sponsors: `aff2432079fbb09fc435a5fe67eeb0d9`

The formula fingerprint covers reward, bonus, credit, commission, MLM, PPV, qualification, maintenance and wallet functions. No earning formula, configuration, point ledger, MIO ledger, sponsor assignment or wallet balance changed during the migration.

## Validation

- `npm run check`
- `node tests/activated-member-trees.mjs`: isolated PostgreSQL migration, free-sponsor rejection, no premature placement, saved-side integrity despite auth metadata change, activation idempotency, old onboarding, former-free activation at branch bottom, three vendors, paid-only generation, continuous paths.
- `node tests/network-ui.mjs`: original four layouts, root photo and country images, three vendors and paid-chain spacing.
- `node tests/interface.mjs`: existing interface regression suite, updated paid-only generation expectation and Pakistan image assertions.
- `node tests/account-dashboard.mjs`: dashboard, dialogs, rank/status and timers.
- `npm run test:referrals` and `npm run test:shopping`: existing shopping/affiliate/referral regressions.
- `npm run build` and `npm run test:pwa`.

Post-migration security advisors have no new warning class; the added private table intentionally has no client-facing policies. No new executable client helper grants were added.
