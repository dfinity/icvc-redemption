# Open Work

## Go-live cutover checklist

A deliberate, mostly irreversible cutover. Do these together, in roughly this order, re-verifying after each. The in-canister engineering is complete (full recovery toolkit: `retryRefund`, `forceRefund`, `sweepBurn`, `forceBurn`, `getDedupKey`, `forceCloseInFlight`); what remains is operational.

- [ ] **Enable II NNS principal derivation.** Get the frontend origin listed in `nns.ic0.app`'s `/.well-known/ii-alternative-origins` (external coordination), then deploy with `ENABLE_NNS_DERIVATION=1` (PRs #18, #28). Until the listing is live, enabling it breaks every login.
- [ ] **Transfer controllership to the ICVC SNS.** Register the redemption + frontend canisters with the SNS (root `nuywj-oaaaa-aaaaq-aadta-cai`) so upgrades go through proposals.
- [ ] **Fund the real ICP pool** (post-cutover). The DAO transfers the ICP pool to redemption on the real ICP ledger; play pre-funding does not carry over. Pool accounting then tracks live `icrc1_balance_of` (see "Phased funding model" in `README.md`).

## Operational hardening (pre-production)

- [ ] **Cycles monitoring.** Add the canisters to cycleops.
