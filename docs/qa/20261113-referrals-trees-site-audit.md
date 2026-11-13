# Referral, tree and site audit — 13 November 2026

## Released behavior

Member invitations use MEM codes with L/R placement; shopping affiliate links use independently generated AFF codes; shopping identities have independently generated USR codes. Existing MIO Member IDs remain stable. Existing records were backfilled and future records receive constrained unique defaults. Legacy links remain resolvable without confusing new User IDs with affiliate codes.

Shopping Users have no network tree. Free Members remain visible in Generation, but are excluded from Binary and Binary Placement. Approved paid activation makes a Member visible at the correct real placement path. Hidden Free ancestors are traversed, never flattened or reassigned. Binary left/right totals and placement level counts now count paid Members only. This migration changes display counts, not rewards, qualification, positions, or ledger entries.

The listing photo grid now fits its panel at small widths; square previews preserve the image and photo errors sit beside the upload control. 1000 × 1000 is recommended, not enforced as a minimum. Existing upload-body and server validation corrections remain in place.

Reviews have readable padding, explicit imported-rating/empty states, recoverable network errors, and pagination guards against stale product/account responses. Keyboard skip links focus the main content without changing pages; catalog anchors route correctly. Long account/referral codes wrap.

## Verification performed

- Complete pre-audit baseline `npm test`: passed, 286 PASS lines, including 133 interface assertions.
- Updated interface suite: 133 assertions passed after layout, review and anchor changes.
- Referral SQL and real application signup-payload tests: Member L/R, customer/AFF, legacy links, direct joins, stale session attribution, code uniqueness and wrong-type rejection.
- Shopping checkout/account suites passed; membership regression applies the actual separated-code migration. Checkout attribution is also covered by the dedicated referral SQL tests.
- Extended membership suite: new MEM L/R signups, Free visibility, paid activation, exact real placement paths, one placement per Member, paid-only totals, User denial, admin visibility, unchanged financial/placement snapshots all passed locally in PGlite.
- Live read-only tree verification after paid-count migration: sample sponsor Generation returned 5 nodes including 1 Free; Binary and Binary Placement each returned 4 nodes with 0 Free; paid downline total was 3, excluding root.
- Browser inspected 58 rendered page/admin-panel snapshots at 320, 390 and 1280 pixels: no document-width overflow. Snapshots use fixture data and actual application markup/CSS; empty queues do not prove populated tables or authenticated live actions.
- Photo preview inspected at 320, 390, 1280 pixels; review layout inspected on mobile. Public live Member and affiliate invitations showed their respective signup forms. Live subscription plans rendered correctly.
- `test:audit`: 18 base pages, 16 static destinations, 62 local assets, unique IDs; review initial/pagination exceptions, retry, stale responses, safe content all passed.
- Syntax checks, build, PWA regression and diff whitespace checks passed.
- Live health advisor had no lints. Catalog audit found no negative stock, invalid price, or approved product lacking image URLs.

## Scope limits

No real signup emails, customer purchases, wallet transfers or paid package activations were generated for QA. Authenticated browser admin/vendor flows were exercised with local test fixtures and database regressions, not a live signed-in account. Page overflow checks are not proof of every visual state. Invalid PIN, unauthenticated permission, insufficient funds and missing required country errors are intentional guards; these were not removed. This report does not claim an error-free guarantee for all future data/network conditions.
