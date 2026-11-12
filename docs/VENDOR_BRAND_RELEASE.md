# Vendor brand registration and review

Vendor signup now requires the owner's name, brand name, logo and proposed commission, alongside the existing invitation and contact fields. Signup uses an isolated auth client and returns to Vendor Account login. Email verification remains required. The auth trigger creates the pending application without granting selling roles or network membership.

Logos use a dedicated 2 MB PNG/JPEG/WebP bucket with authenticated vendor-owned upload paths. With email confirmation enabled, only the selected public logo is retained locally for up to seven days, matched to the login email; no passwords are stored. The first verified login finishes its upload. If the logo draft is unavailable, the pending screen offers a replacement upload. Admin approval requires an actual uploaded logo. Pending vendors see their status, any revised commission offer requiring acceptance, refresh, support and sign-out only.

Approved vendors use Store details to request a name, logo or commission change. Active details do not change before admin approval. One approved name change is allowed; rejected requests can be retried. Logo and commission changes remain available. Admin review requires recent authenticator verification and detects stale requests or changed ownership. Commission changes use the existing setter, including its allocation reset behavior. Historical order snapshots are untouched.

## Verification

- PostgreSQL/PGlite lifecycle tests: mandatory fields, verified email, real-logo approval gate, agreement acceptance, owner isolation, no member/wallet creation, one approved name change, rejected retry, MFA, duplicate/stale approval guards, actual storage RLS.
- DOM interaction tests: isolated signup, login redirect, required fields, credential-free logo draft, pending-only UI, legacy completion, store requests, admin review.
- Existing interface suite: 131 checks passed; account-access and vendor portal tests passed.
- PWA and JavaScript syntax checks passed.
- Desktop and 320/390 px mobile layouts inspected in browser with non-production fixtures.
- Live before/after hash of existing commission/order-placement/binary/auth-profile functions unchanged: c8f7bd32bf0f833bf0230eb1166a65ee.
- Security advisories reviewed: private request table intentionally has no direct client policies or grants; authenticated definer RPCs enforce explicit owner/admin authorization and empty search paths.

No live customer order, vendor signup email, or commission approval was generated for testing. Authenticated behavior was tested in isolation; production rollout is verified by schema and deployed asset checks.
