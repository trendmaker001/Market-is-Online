# Compact tree controls — 12 November 2026

The approved compact layout replaces the tall tree controls. Desktop uses a 37px toolbar; mobile uses two narrow rows totaling 62px. The four selectors remain on one row, with short visible labels and full accessible names on mobile. Back to Network is a text action. The remaining viewport belongs to the original tree drawing.

Member details start closed and open as an overlay. Existing My tree, Previous branch, filter, upline and fit actions remain available in the compact More menu. Keyboard arrows switch tabs. Header and footer return when leaving the graphical route.

## Verification

- `npm run check` and `git diff --check`: pass.
- `node tests/interface.mjs`: all 128 checks pass, including zoom/wheel/fit, search/filter/upline, tree geometry, Free visibility, and full-page navigation.
- `node tests/network-revision.mjs`: pass; signed-in loading, populated/empty/error states, retry, session privacy and route isolation.
- `node tests/shopping-account-ui.mjs`: pass; inline checkout/account and admin controls remain intact.
- Browser fixture using the real application code and synthetic member data: 1200px desktop, 390px mobile and 320px narrow mobile inspected. No horizontal toolbar overflow. Mobile selectors share the same row. Zoom, Fit, Back, tab switching, keyboard arrows and filter menu were exercised.
- Original `sizeTreePanSurface` and all application source after it are byte-identical to the prior release. This includes tree rendering, paid visibility projection, placement and zoom/pan code. No database migration, financial calculation or production data mutation is included.
- Screenshots are fixture evidence, not production member records: `compact-tree-desktop.jpg`, `compact-tree-mobile.jpg`.

The live deployment is verified separately through the GitHub deployment status and exact public asset comparison. This test session does not claim an authenticated production member walkthrough.
