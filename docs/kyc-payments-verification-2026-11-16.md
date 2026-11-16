# KYC and country payments — verification record

## Implemented

- My Profile: uppercase legal name, country calling code, gender, birth date, CNIC/front/back, passport identity page or driving licence/front/back, expiry and selfie.
- Private immutable uploads (5 MB), owner/admin access and expiring document links. Approved identity is locked; administrator corrections invalidate verification.
- Admin Network Controls → Payment Management: KYC reviews, requests, country rates/limits, payment methods, company accounts and audit history.
- Per-country bank, mobile-wallet and USDT settings, separate deposit/withdrawal switches, saved payout accounts and request-time account/rate snapshots.
- Pakistan initial rates: deposit 300 PKR/MIO; withdrawal 290 PKR/MIO. Bank limit 3, mobile-wallet limit 2, crypto limit 1.
- Withdrawal debits available Cash Wallet once; pending amount remains visible. Cancellation/rejection refunds once; completion requires reference and private company receipt. Deposits credit once after admin verification.
- KYC gate on both Proceed conversion and withdrawal; PIN and recent admin authenticator checks remain server-side.
- Digits-only amounts, bounded payloads, request/submission throttles, idempotency, account revision and quoted-rate checks.
- Browser CSP, frame protection, MIME protection, referrer policy, HTTPS policy and updated asset versions. Invoice frames remain same-origin; third-party framing is blocked.

## Completed verification

- Existing full `npm test` regression suite passed before the new payment suite was appended to the default command; new database and UI suites passed separately after final changes.
- `npm run check`, `npm run build`, PWA/public-cache tests, site structure tests and `git diff --check` passed.
- Wallet UI/statement tests passed after adding payment transaction labels.
- Real Chromium via supported browser preview: desktop and 390/360 px mobile KYC, deposit, withdrawal and admin controls inspected with synthetic data. Passport-specific fields, uppercase filtering and 100 MIO → 29,000/30,000 PKR totals checked. Preview applied script/connect CSP directives; deployed response headers require separate live verification.
- PGlite executed the actual payment migration, testing KYC, locks, document ownership, real authenticated-role Storage RLS, wrong-country/foreign-account denial, PIN checks, stale account/rate rejection, ledger conservation, deposit replay, withdrawal refund/replay and expiry.
- Live Supabase migration succeeded. Seven new tables have RLS and no direct anon/authenticated table access; both upload buckets are private. A rolled-back live RPC smoke test verified workspace compatibility and missing-KYC denial without changing balances or member records.
- All 21 previously reported missing foreign-key indexes were added after inspecting their columns and table sizes. Post-migration performance advisor no longer reports unindexed foreign keys.
- `npm audit` reported zero known vulnerabilities for the installed npm dependency tree. This does not certify externally loaded/vendor code or eliminate unknown vulnerabilities.
- Production `dist/` scan found no backup/copy SQL/ZIP/source-map artifacts requiring deletion. Historical migrations and Git history were retained for recovery and audit.

## Scale evidence and limits

A local PGlite fixture with 10,000 synthetic members and 100,000 payment records returned 25-row admin pages. Across 30 reads, median was 46 ms and p95 was 164 ms; EXPLAIN used `member_payment_country_date`. These are local database measurements, **not** a 5,000/10,000 concurrent-browser certification. Production-sized mixed traffic, connection limits, resource saturation and failure recovery still need a controlled staging load test with representative users and infrastructure. No disruptive synthetic traffic was sent to the live site, and no paid infrastructure upgrade was made.

## Operational setup / remaining security review

- Add real company receiving accounts in admin; no bank account was invented. Configure explicit USDT conversion rates before enabling crypto. BEP20 and TRC20 are seeded disabled; the ambiguous additional "POL USDT" network was not guessed.
- Supabase reports leaked-password protection disabled. The connected API does not expose that Auth configuration setting; enable it through the project's Auth settings where supported.
- Legacy security-definer-function warnings remain and require function-by-function review; public catalog/referral functions must not be blindly revoked. Private tables intentionally deny direct access and are accessed through guarded functions.
- Newly created indexes will initially be reported unused until production queries use them; they are not obsolete copies.
- No claim of an intrusion-proof site or guaranteed availability under 10,000 simultaneous users is made.

Country-specific marketplace catalogs and carousels are a separate requested follow-up; they are not part of this release and await the user's approval after a proposed flow.

## Release state

The database migrations are applied. The user explicitly authorized publishing the application code, migrations, security configuration and tests to the existing public `trendmaker001/Market-is-Online` production repository. The Proceed KYC gate remains enabled. Frontend deployment verification is recorded separately after Vercel finishes publishing.
