# Country navigation and independent featured selections

The marketplace country picker now sits on the green navigation bar, to the right of Bundles. It retains saved/manual selection, detected-location fallback, searchable country names and real flag images. The former full-width country banner is removed. Checked in Chromium at desktop, 390px and 360px widths; the dropdown fits within the viewport.

Admin → E-commerce → Shopfront & notices → Featured products now asks for country before vendor/product selection. Product and vendor countries must match. Each country has its own ordered list and unsaved selection draft. Public queries filter by shopping country, and RLS excludes unavailable products or vendors whose country changed. Paginated reads avoid the API's 1,000-row truncation. Empty lists remain empty; no fallback from other countries.

Database migration `20261116192912_country_featured_products` applied successfully. Existing 10 Pakistan picks were preserved. The legacy global list remains as history, and its old setter asks stale tabs to reload. New saves require admin authorization, recent authenticator verification, matching country/product eligibility, an optimistic previous-list check and a per-country transaction lock. Every save is audited. Direct table writes are unavailable to public clients.

Verification:
- Country featured database tests: seed preservation, independent replacement/clear, foreign product rejection, duplicates/nulls, stale writes, 12 selections, admin/TOTP/RLS, direct-write denial, audit, and moved-vendor visibility.
- Full application country integration: country-qualified queries, product/vendor filtering, cart reset, empty-country behavior, foreign deep links, featured display and independent admin drafts/save payloads.
- Existing country/carousel database and UI tests passed.
- Full interface suite: 136 checks passed after the changes.
- Syntax/build/PWA checks passed.
- Payment database and UI tests passed. Corrected the expiry test to use the same UTC date as production; the old test used the host timezone and failed near midnight.
- Prior broad suite was run in segments: the initial legacy visible-rank assertion was updated; remaining suites through audit passed; payment and country suites were then verified independently. No real financial transaction or production test account was created.

Screenshots in `docs/verification/country-nav-mobile.jpg` and `country-featured-admin.jpg` use synthetic fixture data rendered by the real application. Production delivery is separately checked after GitHub/Vercel deployment.

Also includes an SVG foreignObject overflow correction so the achieved-rank badge is fully visible above the avatar. No tree relationships changed.

Production check found the anonymous policy initially called an admin-only role helper. Follow-up migration `20261116193637_country_featured_public_read` separates public eligible-product reads from authenticated admin reads, without granting anonymous access to the helper. The regression fixture now revokes that helper from anonymous clients to match production. Production anonymous SQL returns all 10 Pakistan picks. Vercel deployment `fa5b7fb59ff5ce6b4a0ea36c0fae80e95775029a` succeeded; all five changed frontend assets matched the local build byte-for-byte over HTTPS.
