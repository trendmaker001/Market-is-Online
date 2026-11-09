# Platinum Exchange Wallet

Separate MIO balance backed by private.exchange_wallet_accounts and immutable application-owned private.exchange_transfers. No funds migrate automatically from Cash Wallet.

- Non-Platinum Cash Wallet → Platinum Exchange Wallet.
- Platinum Cash Wallet → own Exchange Wallet only (funding).
- Platinum Exchange Wallet → non-Platinum Cash Wallet; Platinum recipients receive into Exchange Wallet.
- Non-Platinum → non-Platinum is rejected by the backend, including existing transfer RPCs.
- Existing PIN requirements and company-admin TOTP remain required. Free registered, nonblocked accounts can transfer cash. Unregistered/blocked accounts cannot.
- Self funding is excluded from external received/sent totals; period filters are Pakistan calendar years. Current balance is not period filtered. History is paginated and receipts are participant-only.
- Fixed four-decimal amounts, deterministic wallet locks, database transaction rollback and per-sender idempotency keys protect funds. No exchange fee was introduced.
- Existing Cash Wallet earnings, purchase payments, maintenance payments and mint/burn are unchanged. Old ledger receipts remain readable.

## Countdown correction

Maintenance now records first approved activation in started_at. Registration does not start timers. Existing free-account due dates are null. The requested company timers are aligned to the first actual approved activation: 15 days welcome, 180 days monthly, 365 days annual. Existing enabled/rate decisions are preserved. Package upgrades and logins do not extend these deadlines. Other active members' maintenance renewal dates are preserved.

## Validation

PGlite tests cover all tiers, free-member transfers, routing, balances, insufficient funds, four-decimal validation, PIN failure, duplicate requests and payload mismatch, restricted function/table privileges, receipts, totals and pagination. Countdown tests cover inactive records, company repair, activation and upgrades. jsdom checks cover restricted navigation, free dashboard, escaped history, filtering, cancellation, retry key reuse and sign-out cleanup. Financial actions were not executed against live accounts for testing.

## Transfer receipts and dashboard balance
- Exchange history has a Receipt / View action for sent, received and self-funding entries. It uses the existing participant-only `lookup_mio_transfer_receipt` RPC, verifies the returned transfer and participant, and clears the dialog on sign-out or package change.
- The receipt shows the existing site logo, Transfer Receipt title, Pakistan date/time, sender and receiver names/codes, recorded source/destination wallets, reference and exact amount (up to four decimals). No footer domain or print control is shown.
- Download creates a PNG locally in the browser with the same record details; no third-party rendering service or wallet mutation is involved.
- Only a PREMIUM (Platinum) dashboard requests and displays the Exchange Wallet balance. The card links to Exchange Wallet. A failed balance read displays an unavailable marker rather than a fabricated zero. Admin member previews use the selected member's separately retrieved exchange balance.
- Verification: receipt and exchange UI tests, dashboard tier visibility, admin member preview, existing exchange database tests and interface checks; local desktop/mobile browser preview and successful PNG download. No live member transfer was executed for QA.
