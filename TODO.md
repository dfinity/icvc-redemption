# Open Work

Operational and infrastructure items pending. None block the current play-canister deployment; each should be closed before a real-value rollout.

## Go-live cutover checklist

A deliberate, mostly irreversible cutover. Do these together, in roughly this order, re-verifying after each. The in-canister engineering is complete (full recovery toolkit: `retryRefund`, `forceRefund`, `sweepBurn`, `forceBurn`, `getDedupKey`, `forceCloseInFlight`); what remains is operational.

- [ ] **Switch to the real ledgers.** Repoint redemption at the production ICVC token + NNS ICP ledger (`ryjl3-tyaaa-aaaaa-aaaba-cai`), update the frontend `config.js` ledger ids, and confirm `deploy.sh` reseeds no balances (`DO_LEDGERS=0` already holds for `-e ic`). Core step the rest depend on.
- [ ] **Finalize and freeze the fair-value rate.** Pull a final treasury snapshot (ICVC supply, treasury ICP + nICP, WaterNeuron `get_info.exchange_rate`), bake the constants via an upgrade, then leave them fixed. Inputs currently reflect the **2026-06-18 COB** snapshot (rate `5_758_856` e8s); re-pull at the prod cutover if the treasury has moved.
- [x] **Remove the faucet.** Done: deleted the `faucet` method + cooldown state + ICVC pre-funding + the SPA faucet card; tests fund users via ledger genesis balances / minting instead.
- [ ] **Enable II NNS principal derivation.** Get the frontend origin listed in `nns.ic0.app`'s `/.well-known/ii-alternative-origins` (external coordination), then deploy with `ENABLE_NNS_DERIVATION=1` (PRs #18, #28). Until the listing is live, enabling it breaks every login.
- [ ] **Transfer controllership to the ICVC SNS.** Register the redemption + frontend canisters with the SNS (root `nuywj-oaaaa-aaaaq-aadta-cai`) so upgrades go through proposals rather than the `icvc-mainnet` operator key (`jaad2-…-xae`); afterward, remove the individual operator principal as a controller. Supersedes the backup-admin item below for the production end state, and retires the current single-operator setup (the `icvc-mainnet` identity + PEM live on `@bjoernek`'s machine).
- [ ] **Final security review.** Full review of the production-shaped deployment: real ledgers, faucet removed, derivation enabled, final rate, admin + controller custody, and the end-to-end redeem/refund flow against real value. The [canister-security skill](https://skills.internetcomputer.org/skills/canister-security/SKILL.md) is one input, not the whole review.
- [ ] **Fund the real ICP pool** (post-cutover). The DAO transfers the ICP pool to redemption on the real ICP ledger; play pre-funding does not carry over. Pool accounting then tracks live `icrc1_balance_of` (see "Phased funding model" in `README.md`).

## Operational hardening (pre-production)

- [ ] **Backup admin.** Only one admin principal on the allowlist today (`jaad2-…-xae`); losing that key locks out in-canister admin actions (`pause`, `retryRefund`, `forceRefund`, etc.). Add an independent backup principal via `addAdmin` and verify with `listAdmins`, so admin actions don't hinge on a single key. (Platform-level control is covered separately by the SNS controllership transfer above.) See `RECOVERY.md` §5–6.
- [ ] **Cycles monitoring (audit L3).** No monitoring today; a freeze strands in-flight redemptions and blocks upgrades. Wire an external watcher alerting at 90 days of headroom, and document a "low cycles" runbook in `RECOVERY.md`.
- [ ] **Re-add the PR rule on `main`.** Ruleset `16932107` keeps the deletion/force-push restrictions and the `mops test` check, but the "require a pull request" rule was dropped during solo maintenance (a sole CODEOWNER can't approve their own PRs). Re-add it (1 approval, require Code Owners) once there's an active reviewer.
