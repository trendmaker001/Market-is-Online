# Network Controls reporting — 7 November 2026

Cards aggregate all registered member profiles, including company and founder accounts. Wallet figures are current balances, not lifetime credits. Counts use the same current-package function as the network and include zero-balance members. Member and fee records use server pagination and admin-only RPCs.

Company Fees reports actual gross company_fee on approved paid activations after the existing financial reset, excluding SHOPPING_PPV activations, plus recorded Proceed conversion fees. This report does not add a second wallet credit. Withdrawal and E-commerce categories remain unconfigured pending the owner’s rules; they are excluded from the combined figure.

MIO price changes are audited and recalculate current catalog PPV. New member/guest orders snapshot the configured rate; checkout allocations and reward release use that saved rate. Existing order and ledger snapshots are untouched. USD exchange-rate configuration remains separate. Network percentage denominators, bonus wallet routing, and Proceed distribution percentages are unchanged.

## Database deployment
Applied migration: network_control_totals_and_mio_rate. Source order:
1. schema/network_control_reporting.sql
2. schema/network_control_mio_rate.sql
3. schema/network_control_mio_price_setter.sql

## Validation
- Full npm test suite passed, including 103 interface checks.
- 1,010-member aggregate fixture verifies full counts, current tiers, search/pagination, and all four balances.
- Fee fixture verifies 50 subscription + 5 Proceed = 55 MIO, excludes pending/PPV/pre-reset fee records.
- Price fixture verifies 300 → 290 updates current catalog and new order PPV without changing old orders.
- UI tests cover first open, tiers, pagination, search, fee drill-down, price save/refresh, errors and sign-out cleanup.
- Live admin summary and detail RPCs verified. Live rate setter exercised in a rolled-back transaction; current rate remains 300.
- Anonymous execution is denied. Security advisor’s three new authenticated-definer notices correspond to the intentionally admin-guarded report endpoints.
- Existing Manager, Community, Proceed conversion, Rank and bonus-routing function hashes unchanged.
- Browser verified unauthenticated admin redirect; authenticated browser QA was unavailable in this session.
