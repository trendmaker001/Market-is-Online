# Shopping Users, advance payments and sponsor security

All new public Join/checkout signups create a shopping User identity, not network membership. Verified email and accepted shopping terms are required to place an order. Vendor onboarding, protected founder invitation and administrator provisioning retain their existing paths. Membership is an explicit later action using a valid eligible member referral; customer orders and payment history remain owned by the same auth identity.

## Amounts

Use the final discounted order total including delivery. Through PKR 6,000, cash advance is PKR 600 (capped at the whole total for smaller orders) or refundable sponsor security of 2 MIO. Above PKR 6,000, cash advance is 10%, rounded to paisa; security is that PKR amount converted at the order's snapshotted MIO rate, rounded upward to four decimals. At the live reference rate of PKR 290, 2 MIO is PKR 580; the cash minimum remains the requested rounded PKR 600.

Advance and security are mutually exclusive per order. A verified advance reduces `orders.cod_due_pkr`. Sponsor security never reduces COD. Existing member wallet/Shopping Points checkout is unchanged; member purchases made through selling links retain affiliate attribution and use authenticated shopping ownership.

## Administration

E-commerce Control Centre → Orders → Customer advances & payment accounts:

- Add/edit bank or wallet name, account title, number/IBAN, instructions and active state. No bank details are inferred or invented.
- Review a submitted transaction ID against actual bank records; enter the exact verified amount and a note. Approval confirms the order for fulfilment but does not mark its full payment as collected.
- Reject invalid claims with a note so the customer can correct and resubmit.
- Resolve submitted payments before cancelling an order. Approved advances on cancelled/returned orders become `refund_due`; record the real refund reference after refunding the advance. COD refunds, if any, must also be reconciled through the existing operations process.

Affiliate security requests remain in the linked member's Orders approval area. Free members retain the existing PPV/delegated sponsor choices; all supported hold paths use the order's recorded amount and release it exactly once.

## Security and verification

Customer identity, payment accounts and funding records live in private RLS-enabled tables with no direct client privileges. Authenticated RPCs enforce ownership and admin role. Order triggers block fulfilment/full payment confirmation until the chosen advance or sponsor guarantee is approved. Anonymous new checkout is disabled; legacy receipt tokens still work for existing guest orders. Customer cancellation also closes a pre-existing NULL-buyer authorization gap.

Tests: `npm run test:shopping`, `node tests/interface.mjs`, `node tests/account-access.mjs`, `node tests/checkout-wallets.mjs`, `node tests/vendor-portal.mjs`, `npm run check`.

The UI tests use jsdom, not a real authenticated browser or email inbox. Production smoke tests must be rollback-only and must not leave test orders, stock changes, wallet entries or payment accounts behind.

Production verification (11 November 2026): rollback-only checks passed for shopper identity isolation, duplicate checkout, cross-user cancellation denial, unfunded dispatch denial, verified advance approval, COD balance, refund tracking, stock restoration and the amount formula. The deployed HTML/JS/CSS returned HTTP 200 and exactly matched the tested files. The production-only signup gender trigger was corrected for explicit shopping User registration and is covered in the test fixture. No bank account details were configured in the existing site; an administrator must add the real receiving account before customers can submit advance payments. Real-browser email verification and authenticated UI testing remain unverified because the available browser could not reach the site.
