# Tree panels, responsive layouts and A4 invoice downloads

## Changes

- Vertical Info/Search/More toolbar; mutually exclusive panels with close controls and Escape handling. Blank taps dismiss panels; drags, panning and multi-pointer gestures do not.
- Search/filter/member panels fit beside the tool rail. Original tree rendering, paid visibility, placement and financial calculations remain unchanged.
- Scoped narrow-screen fixes for cart controls, membership request details, account headings, balances, order totals and forms. Modal scroll locks prevent duplicate background scrolling.
- Shared admin/customer Download slip menu offers order summary, each vendor and all vendor slips. Each vendor starts on a separate A4 page; long invoices repeat table headings.
- Downloadable PDFs use local, lazy-loaded pdfmake 0.3.14 with embedded fonts. Invoice data comes from the existing authorized order RPC and stored vendor shipment snapshots. Sponsor security is not deducted as payment.

## Verification

- Full `npm test`: passed, including 129 interface checks and financial, wallet, checkout, vendor, bundle, authorization and reporting regression suites.
- `npm run test:shopping`, `npm run test:orders`, `npm run test:invoice`, `npm run check`, `git diff --check`: passed.
- Real browser fixture using current production application source: tree panels at 390px and 1200px, shopping account sections at 320px and 1200px, cart at 320px, and admin/customer order/invoice screens at mobile/desktop widths.
- Search, filter, close buttons, Escape, blank-tap dismissal and drag preservation exercised. No document horizontal overflow in inspected account/cart layouts.
- Actual browser vendor PDF download inspected: one A4 page, correct vendor-only items, allocated advance, delivery and remaining COD. Rendered barcode and QR successfully decoded.
- Real generated PDF fixtures: single vendor = 1 A4 page; two vendors = 2 A4 pages; 40-product invoice = 3 A4 pages, repeated table headers and unclipped totals/footer.
- Screenshots and sample PDF use synthetic QA records, not customer data. The sample PDF is not a real invoice.

## Scope and limitations

No database migrations, balance changes, order mutations or placement changes are included. Authenticated production member/admin transactions were not performed; those flows were exercised with fixtures and database regression tests. Deployment readiness and live asset equality are checked separately after publishing. This is evidence for the tested flows, not a guarantee that every possible website state is error-free.
