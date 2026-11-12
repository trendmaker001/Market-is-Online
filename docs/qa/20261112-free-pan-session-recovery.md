# Free tree movement and session recovery

## Changes

- Replace bounded native scrolling with an unbounded tree camera. Mouse/touch drag can continue in either direction. Zoom anchors, pinch midpoint, search centering and Fit use the same camera coordinates.
- Preserve tree artwork, geometry, eligibility filters, placement and business formulas.
- Wait for Supabase session initialization before password sign-in. Recover only recognized missing/expired session errors; retry password authentication at most once for those errors.
- Keep invalid credentials, permission failures and network errors visible. Local sign-out does not revoke other devices. Fallback cleanup is limited to this project's auth storage key.
- Ignore outdated startup/session callbacks so an earlier session read or sign-out does not overwrite a newer sign-in.
- Bump app and tree stylesheet asset versions.

## Verification

- Interface suite: 130 passing checks, including very large positive/negative drag deltas, anchored zoom, pinch-to-drag transition and Fit recovery.
- Auth recovery suite: initialization ordering, missing/expired refresh state, narrow local cleanup, bounded retry, invalid credentials and network errors preserved, absent-session rejection, startup/sign-in races and queued sign-out isolation.
- Account access: 11 role-routing cases passed. Workspace access suite passed, including revoked/missing access and identity races.
- Shopping suite passed: checkout/signup, sponsor and advance formulas, ownership/permissions, membership requests and paid-only binary visibility regressions.
- JavaScript syntax checks and whitespace checks passed.
- Browser fixture with production tree code: desktop repeated dragging past the former area, mobile dragging and Fit recovery checked. Touch pinch behavior is covered by source-level tests, not a physical-device test.

## Limits

No production passwords were available for end-to-end sign-in to real customer, member, vendor or admin accounts. Auth tests use controlled SDK responses; role authorization checks remain unchanged. No database migration, permission change, payment, order mutation or financial formula edit is included in this release.
