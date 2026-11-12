# Installable PWA and sidebar-only sign out

Implemented a standalone, same-origin PWA with the existing M emblem (no wordmark) in 192/512, maskable and Apple icons. The install entry mounts in member, customer, vendor and admin navigation and in the public marketplace footer. Pending vendors retain support, installation and sign out access without opening unapproved selling tools.

The service worker caches only public offline HTML and brand icons. Navigations use the network; APIs, authentication, account data, payments and mutations are neither cached nor queued. Updates wait for the user's Update & reload action; reconnect and first installation never reload an unfinished form automatically. Build output hashes frontend files and icons into the worker release.

Header Sign out stays hidden; existing member/customer sidebar handlers remain, and vendor/admin sidebar handlers delegate to the existing logout flow. No financial, referral, placement or commission formula changes.

Validation:
- PWA regression suite passed: icon dimensions/manifest, public-only caching, fresh navigation and offline fallback, update activation, install prompt cancellation/consumption, iOS help, dynamic sidebars, standalone visibility and reconnect behavior.
- 131 interface checks passed, including signed-in header hiding and sidebar logout clearing private history.
- Auth recovery/account/workspace access tests and vendor portal UI checks passed.
- JavaScript syntax checks and git diff whitespace checks passed.
- Chrome browser preview: install panel at 320px, 390px and 1200px viewport widths; no panel horizontal overflow; close and Escape work. Member/customer navigation install entries observed.

Limits: responsive browser previews and mocked lifecycle tests are not physical Android/iPhone installation tests. Native install availability depends on browser support; iOS uses Safari Add to Home Screen. Authenticated production actions were not submitted for this release.

## Installation retry correction

Browser Download App entries now remain visible after prompt cancellation, acceptance and the browser's installation event. They remain hidden only when actually running in standalone/app mode (including iOS standalone). The install action becomes installation guidance when no reusable native prompt is available; it consumes each browser prompt once and accepts later fresh prompts. Samsung Internet, Android Chrome and iOS each receive relevant instructions, with expandable missing-icon guidance. Messages no longer claim an app-launcher icon is ready merely because the browser reported installation.

Regression tests cover repeat opening, cancellation, fresh prompt retry, late-mounted navigation, Samsung guidance, browser visibility after appinstalled and hiding in app mode. A 320px Chrome preview verified close/reopen and visible install help. Physical Samsung installation remains unverified.
