# Administrator member migration

Account Holders → Open keeps the administrator session and displays the selected member's dashboard. The shared graphical tree preserves the selected root when changing tree tabs or returning Home. All-level views are paged by branch at the existing 500-node rendering limit.

The directory shows **Placement Name**, **Placement MIO ID**, and **Left / Right**, independently of sponsor details. The edit menu supports:

- Package entitlement, leadership rank and account status. Migration entitlements have no purchase amount, volume allocation or activation bonus. Restoring rank history does not release Promotion Points. Subsequent genuine earnings and promotions use normal rules.
- Actual Cash, Proceed, Shopping, Promotion and eligible Platinum Exchange balances. Each save records the adjustment and before/after audit. Opening earnings never create wallet credit.
- A single opening total per earnings category. The user sees a separate opening statement; newly earned transactions keep their actual history. Opening 1,000 plus newly earned 30 displays 1,030.
- Monthly/annual remaining days and monthly PPV progress. Stored deadlines continue counting down. Unchanged fields retain their deadline.
- Personal points, working Direct Points, TNGP, left/right DP/GP/BRP and lifetime/remaining BP. Shopping Points are a separate spendable wallet. Opening binary consumption keeps carried BP usable by the normal binary-share calculation.
- Sponsor and binary placement changes. The server rejects cycles, occupied positions and changes to permanent company/founder relationships. Moving a branch retains descendants and recorded points.

Every management save requires an actual admin role, a recent authenticator verification, a reason, an unchanged section snapshot and a request UUID. Retrying the same request returns its prior result. Request UUID reuse with different data is rejected. Profile corrections remain limited to contact fields; users can edit their own profile without gaining role or wallet permissions.

## Creating a free member

Open a member in the tree, choose Add left or Add right, enter the new email/profile, sponsor and placement, and verify creation. The Edge Function verifies the caller and calls the admin/TOTP-guarded reservation RPC before using server-only Auth Admin credentials. The Auth trigger validates the reservation and atomically creates the profile and exact placement. Duplicate emails, invalid reservations and occupied positions are rejected.

The new account is unconfirmed and has no recorded terms consent. A password setup email is sent only if the administrator selects that option. The member can also use Forgot password. The member verifies their email, chooses their own password and accepts the terms; provisioning never marks consent on their behalf. Existing auth accounts cannot be replaced by this flow.

## Deployment order

Apply `admin_member_profile.sql`, `account_holder_countries.sql`, `admin_member_management.sql`, `admin_member_provisioning.sql`, then `admin_member_snapshot_imports.sql` as one reviewed migration. Deploy `supabase/functions/admin-create-member/index.ts`, keeping JWT verification enabled, then publish the frontend. This schema migration changes no existing member balances or earnings.

## Validation

PGlite tests cover real schema/trigger behavior, migration ledgers, idempotency, concurrent-edit rejection, exact countdowns, opening-plus-new earnings, rank/payout isolation, usable binary carry, cycle/position validation, verified-email onboarding and authority checks. UI tests exercise the shared SVG tree, edit dialogs, retained retry keys, and logout isolation. The Edge handler is tested with isolated Auth clients. Desktop and 390px mobile layouts are visually checked with local fixtures.

Production deployment checks confirm migration/function existence and permissions, Edge deployment status and matching frontend asset hashes. Sending a real setup email and saving through a real authenticated admin browser are not part of fixture-based verification.
