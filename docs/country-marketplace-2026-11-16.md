# Country marketplace release — 16 November 2026

## Behavior

The storefront uses a remembered explicit shopping-country choice first, otherwise Vercel's country header, then the signed-in profile country if available. When none is available it asks the visitor to select a country. The geolocation endpoint is private/no-store and does not store IP addresses. Shopping country does not change profile, KYC, or payment-country settings.

Product queries require both the product and its active vendor to match the shopping country. Vendor directories, featured products, search, product links and bundle vendor selection use that scoped catalog. Switching countries clears the cart, bundle selections, checkout draft and old storefront media; stale async responses cannot restore the previous country's content. Unknown or unconfigured countries show empty results, without cross-country fallback. Category taxonomy and bundle templates remain shared, with country-scoped products/vendors.

Admin → E-commerce Controls → storefront → Promotional Banners & Media has a Promotion country selector. Main carousel, second carousel, promotional images, category artwork and video settings are independent per country. Unsaved country drafts remain separate; save each country individually. Admin vendor cards include Marketplace country, updating the vendor and its product country codes together.

The existing announcement popup and ticker remain Pakistan-only. This release does not add country-specific pricing/currencies or geographic access restrictions to otherwise public product data. Visitors can change shopping country explicitly.

## Database and security

Migration: `20261116180733_country_marketplace_presentations.sql`.

The new table has RLS enabled and no anonymous/authenticated direct table access. Public read RPCs return published country media only. Writes require an administrator and recent authenticator verification, validate countries and media URLs, use optimistic revision checks, and write an audit event. Vendor country moves are atomic. A product trigger rejects conflicting product/vendor countries.

Production migration applied successfully. Existing Pakistan media was preserved (6 main slides). Missing vendor country was recovered from its existing owner's Pakistan profile; 29 missing product countries were filled from their vendors. Read-only verification found 3 active Pakistan vendors and 29 available products; UAE had no configured banners/products. No customer identity/payment records or historical orders were changed.

Supabase advisor comparison introduced no new security warning categories. The new RLS/no-policy informational finding is intentional because the table denies direct access. Existing legacy function warnings and leaked-password protection warning remain outside this release.

## Verification

- PGlite executes the migration and tests backfill, country isolation, unpublished media, admin/TOTP gates, grants, stale revisions, unsafe media URLs, vendor moves and product-country consistency.
- UI tests cover geo/manual priority, persisted choice, invalid countries, unknown-location selection, separate admin drafts/saves and stale media responses.
- Full application integration covers actual product/vendor country query filters, directory results, empty countries, cart reset and foreign product deep links.
- Existing interface suite: 136 checks passed. Premium marketplace, marketplace catalog, bundles and feedback tests passed.
- Syntax, static assets/site structure, PWA build and worker tests passed.
- Browser preview verified Pakistan versus UAE selection on desktop and 390/360 px iframe viewports. No horizontal document overflow at either mobile width; Pakistan banner images rendered. Authenticated production admin writes were not exercised with a real administrator session; they are covered by UI/database tests.

Production deploy and live HTTP/browser results are recorded in the final delivery message. No 5,000–10,000-user load test was run for this release.
