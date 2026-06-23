# Open Work

## Go-live cutover checklist

A deliberate, mostly irreversible cutover. Do these together, in roughly this order, re-verifying after each. The in-canister engineering is complete (full recovery toolkit: `retryRefund`, `forceRefund`, `sweepBurn`, `forceBurn`, `getDedupKey`, `forceCloseInFlight`); what remains is operational.

- [ ] **Transfer controllership to the ICVC SNS.** Register the redemption + frontend canisters with the SNS (root `nuywj-oaaaa-aaaaq-aadta-cai`) so upgrades go through proposals.
- [ ] **Fund the real ICP pool** (post-cutover). The DAO transfers the ICP pool to redemption on the real ICP ledger; play pre-funding does not carry over. Pool accounting then tracks live `icrc1_balance_of` (see "Phased funding model" in `README.md`).

## Operational hardening (pre-production)

- [ ] **Cycles monitoring.** Add the canisters to cycleops.

## Known limitations (accepted, not scheduled)

- **Wallet "Send" has no dedup (`created_at_time` not pinned).** The SPA's Wallet → Send issues `icrc1_transfer` (ICVC) / the ICP ledger's legacy `transfer` (ICP) with `created_at_time` unset, so if a send commits but its response is lost and the user retries, a second real transfer can settle. **Accepted as low-priority:** it only moves the *user's own* funds to a destination *they* chose (typically themselves), needs a lost-response + manual retry to trigger, and can't be triggered by anyone else or affect the pool/protocol. A proper fix (pin a per-send `created_at_time`, reuse it across the user-driven retry, treat `Duplicate` as success) is fiddly in the current flow — the retry is a fresh form submission, not a re-confirm — and carries a browser-clock-skew caveat, so the value/effort isn't justified for a self-send feature. The redeem/refund/burn paths that move *protocol* funds ARE dedup-pinned. Revisit if the Send feature is ever used for material third-party transfers.
