# Manager Bonus Wallet

Manager points accrue prospectively after Team Manager qualification. An immediate qualified sponsor receives MDP from eligible direct DP activity, never MNGP for the same direct. Indirect GP activity belongs to the nearest qualified manager at sponsor depth 2–10. A qualified manager stops the branch even while inactive. A source who is already a Team Manager is outside the upstream manager branch. Existing package/maintenance eligibility remains required.

Only `admin_distribute_manager_bonus` pays pending points. Existing editable rates (currently 5% MDP / 10% MNGP) remain in use. The RPC requires an administrator and recent TOTP. It locks pending balances and the treasury, reserves existing generation/binary manager funding, posts linked distributions and bonus transactions, and clears paid pending balances atomically. Retries with the same trimmed key return the original cycle. Insufficient funding rolls back without using other bonus pools.

`private.manager_bonus_pool_allocations` links each distribution cycle to original package/order reserves. Only the two manager reserve categories are reduced. The bonus funding guard verifies the distribution, beneficiary, amount, cycle and funding before posting. Existing wallet routing remains unchanged (production currently routes Team Manager to Proceed). No migration executes a distribution.

Admin Manager Bonus Wallet shows funded, paid, available, pending and eligible totals, funding sources and paginated payments. Member status retains pending MDP/MNGP and adds lifetime totals and recent payments; full payment history remains in Earning History. Internal `MTP` columns remain compatible and are displayed as MDP.

## Validation

- `npm run test:manager-funded`: qualification timing, direct/indirect exclusivity, depth 10/11, breakaway including inactive managers, TOTP, funded atomic distribution, retry protection, reserve isolation, configured wallet routing, history and access control; admin wallet UI totals, references, pagination and escaping.
- Existing manager, bonus routing, community funding, dashboard, interface and PWA tests.
- `npm run check` and `npm run build`.
- Live post-migration read-only checks: zero existing manager qualifications/points/distributions; Cash and income wallet snapshots unchanged; treasury source row values equal the original source function; no funding allocations or payments created. Public/private RPC permissions verified.

Database migration applied November 24, 2026. Frontend deployment is a separate release step.
