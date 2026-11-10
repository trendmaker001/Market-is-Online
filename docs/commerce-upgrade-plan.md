# Commerce and vendor upgrade

Approved scope: product-specific commission and editable capped PPV; vendor registration separate from network membership; member vendor referrals and commission history; approved Seller Portal design; complete bundle component details; remove homepage Featured Categories; compact consistent admin controls.

Latest decisions: MIO personal/affiliate level 1 70%, sponsor level 2 20%, second sponsor level 3 10%. Introducer receives 10% of product commission before PPV. Company fee 5% of product price, PPV network fee 10%. Admin selects reserve or customer discount when assigning less than maximum PPV. No historical financial entries are rewritten.

Delivery order and verification gates:
1. Bundle component page: gallery, accessible product tabs, full descriptions, original product links. Functional tests, checkout/stock regression, desktop/mobile browser QA before next implementation task.
2. Product commission/PPV admin controls and accounting: deterministic calculations, caps, discount/reserve selection, new-order snapshots, 70/20/10 MIO, introducer credit once. Database tests including authorization, budget conservation and retry protection; form UI and responsive browser QA.
3. Vendor account separation and Seller Portal: invitation attribution, pending application, approval, seller-specific login routing, scoped products/orders/settlements, member referral dashboard. Backend role/ownership tests and UI tests.
4. Admin design review: all existing workspace panels; simpler labels, consistent compact headers, fields, actions and tables. Preserve business controls and data. Check desktop/mobile and affected regression tests.
5. Full npm run check and npm test; migration validation; existing Vercel production deployment; public site verification.

Every stage must pass its relevant functional and UI checks before moving to the next implementation stage. Production publication only after complete final checks. Existing members/vendors/orders and ledger history preserved. No real test purchases or transfers on production.

Progress and verification:
- Latest production source: 31c6467251f94b23336c0d172a1c7a56c6268c42; fetched again before release preparation.
- Bundle component descriptions, photos, keyboard tabs and original product links implemented. Bundle UI and checkout/stock regression checks passed.
- Product Commission (%) and capped Assigned PPV implemented with explicit reserve/customer-discount selection. Database tests passed for 20%/30% calculations, mixed bundle margins, catalogue migration, immutable old snapshots, authorization and duplicate-credit prevention. Mobile/browser form rejects excess PPV.
- Separate vendor identity, verified-email application, immutable introducer, accepted agreement and admin approval implemented. Vendor product ownership and seller-order authorization tested. Member referral dashboard and Seller Portal tested on desktop and mobile with local sample data.
- All 33 admin sections reviewed at desktop and mobile widths. The Community Share overflow was corrected. Searchable control navigation, consistent headings, compact product filters, horizontally scrollable product rows and mobile review panel verified. Existing financial controls remain in place.
- Homepage Featured Categories removed; category directory and its management controls preserved.
- Final release gate passed: npm run check, npm test, npm run test:maintenance and npm run test:dashboard (exit 0). Interface suite: 118 interaction checks.

Test boundaries: Browser admin/vendor reviews use local fixtures. Database integration tests use PGlite with the repository schema and new migrations. No production purchase, transfer, email registration, payout or admin configuration was submitted as a test. Live authenticated UI and actual verification-email delivery require a real authenticated session; do not represent local fixture testing as production workflow verification.

Production data guard: new pricing changes catalogue calculations and future order snapshots only. Existing order and financial ledger records must remain unchanged. Existing published bundles are recalculated; an underfunded bundle is kept as a draft for review. Component economics changes block stale bundle checkout until its settings are refreshed.
