# UI and country controls release

## Changes

- Shared responsive spacing, input sizing, readable mobile navigation, compact green/orange countdowns, dark-theme contrast, and contained tables and PIN forms.
- Fixed the mobile admin summary grid, duplicated dashboard country label, and notification badge position.
- Cart wording and shopping-cart icon throughout visible checkout UI.
- Edge-to-edge, image-only homepage carousel with three-second rotation; pauses on hover/focus, hidden tabs and reduced-motion preference.
- Required signup gender with matching fallback avatars in dashboard and network trees; uploaded photos retain priority.
- Country-required seller applications and product submissions, country display in review/listings, and admin product-country editing.
- Audited, recent-TOTP-protected monthly-maintenance country controls. Country OFF exempts monthly maintenance only. Annual requirements, existing deadlines, order snapshots and financial history are preserved.
- Approved sellers see product management first; another-business application remains available on demand.
- Public About, Shopping Guide and Seller Guide pages, sitemap, robots file, canonical metadata and truthful structured data.

## Validation

- Syntax checks for app and dashboard scripts.
- 101 source-level interface interaction checks.
- Dashboard, activation-offer and founder-activation suites.
- Checkout-wallet, manager/community/super-member, maintenance and security-migration suites.
- Country-control database tests: admin authorization, country validation, successful product/vendor submissions, legacy RPC bypass revocation, required email-signup gender, self-only dashboard identity, tree identity and annual/monthly independence.
- Browser inspection of the real public marketplace and Cart dialog.
- Local authenticated fixtures at 390px and 320px for dashboard, profile, network, wallet, transfers, transactions, earnings, e-commerce, orders, packages, security, seller, listing/application, signup and admin layouts; desktop seller and marketplace review.

Authenticated browser fixtures contain sample data, not production member transactions. No real purchase, payout or withdrawal was performed for UI testing. Existing missing product/vendor country and member gender values are not guessed; new submissions must provide them.
