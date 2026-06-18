# ICVC Redemption Canister

[![Tests](https://github.com/dfinity/icvc-redemption/actions/workflows/test.yml/badge.svg)](https://github.com/dfinity/icvc-redemption/actions/workflows/test.yml)

Canister for winding down the **ICVC DAO** on the Internet Computer. Token holders swap ICVC for ICP at a **fair-value rate derived from the DAO treasury's backing**: `(treasury ICP + treasury nICP valued in ICP) ÷ total ICVC supply`. As of the 2026-06-18 COB snapshot this is **0.05758856 ICP per ICVC**. The inputs are baked into the wasm as constants (with a recorded timestamp) and change only via upgrade; `getFairValueInputs()` exposes the live breakdown. The canister is deliberately **not autonomous** at the edges — admin plays an active role in recovery (see [`RECOVERY.md`](./RECOVERY.md)).

> **Status: play deployment only.** This canister is on IC mainnet but only **play ledgers** are connected — both the ICVC ledger (`zekdo-fyaaa-aaaae-agadq-cai`) and the ICP ledger (`yjeha-kqaaa-aaaae-agaea-cai`) are our own deployed copies of the official ICRC-1 ledger wasm, **not** the production ICVC token or the NNS ICP ledger. The redemption logic, saga journal, admin allowlist, and test suite are production-shaped.
>
> **Prod prep:** `main` is being readied for a real-value deployment — the test **faucet has been removed** (a production wind-down has none; holders bring the ICVC they already own), and a prod deploy points at the real ICVC token (`m6xut-mqaaa-aaaaq-aadua-cai`) and the NNS ICP ledger (`ryjl3-tyaaa-aaaaa-aaaba-cai`). The play deployment above stays live (tagged `play-v1`).

## Architecture

```
                ┌────────────────────────────────────────────────────┐
                │                  Internet Identity                 │
                │                 (rdmx6-…-aaadq-cai)                │
                └──────────────────────────┬─────────────────────────┘
                                           │ auth
                                           ▼
┌──────────────┐    HTTP+JSON     ┌────────────────┐
│   Browser    │ ───────────────► │  frontend      │  asset canister
│ (vanilla JS) │                  │  src/frontend  │
└──────┬───────┘                  └────────┬───────┘
       │ icrc2_approve(canister, amount)            ▲
       ▼                                            │
┌──────────────┐                                    │
│  icvc_ledger │◄────────────────────┐              │ stats / history
│ (ICRC-1/2)   │   icrc2_transfer_   │              │
└──────────────┘   from              │              │
       ▲                             │              │
       │ icrc1_transfer (refund)     │              │
       ▼                             │              │
┌──────────────────────────────────────────────────┐│
│  redemption  (Motoko)             ICVC ────────► ││
│  src/redemption/                                 ││
│  - main.mo     entrypoint + redeem flow          ││
│  - Pure.mo     pure helpers (unit-tested)        ││
│  - Types.mo    domain types                      ││
│  - Ledger.mo   ICRC-1/2 client interface         ││
│                                                  ││
│  ICP ────────►  icrc1_transfer  ─────────────►   ││
└──────────────────────────────────────────────────┘│
       │                                            │
       ▼                                            │
┌──────────────┐                                    │
│  icp_ledger  │                                    │
│ (ICRC-1/2)   │────────────────────────────────────┘
└──────────────┘
```

**Swap flow:** user `icrc2_approve`'s the redemption canister on `icvc_ledger` → calls `redemption.redeem(amount)` → canister pulls ICVC via `icrc2_transfer_from` → sends ICP via `icrc1_transfer` → **burns the redeemed ICVC** (transfers it to the ledger's minting account, removing it from supply). The flow is non-atomic by construction; the burn is the final step and runs only after the ICP send succeeds, so a failed swap is still refundable. Redemptions have a **10 ICVC minimum** (below that, `redeem` returns `#BelowMinimum`). Every step is journalled in `inFlight` (the *saga journal*) so a trap, upgrade, or ledger failure leaves a recoverable trail. See [`RECOVERY.md`](./RECOVERY.md) for the full state machine.

**Frontend (the SPA).** A static vanilla-JS app served by the asset canister. Holders sign in with **Internet Identity**, then use:

- a **Swap** view — enter an ICVC amount (or **MAX**), see the ICP they'll receive at the current rate, and confirm; the app runs the `icrc2_approve` → `redeem` pair for them;
- a **Wallet** view — live ICVC and ICP balances (`icrc1_balance_of`);
- an **exchange-rate panel** with an ℹ toggle that shows the full fair-value derivation from `getFairValueInputs()` (treasury ICP + nICP, total backing, ICVC supply, snapshot date);
- a **pool stats** card with the "X distributed of (X + remaining) ICP in pool" progress bar (`getStats`) and recent redemption history (`getRedemptionHistory` / `getUserRedemptions`).

The SPA does not (yet) expose any recovery actions — refund retries and all admin/recovery methods go through `icp` (see [`RECOVERY.md`](./RECOVERY.md)).

## Quick start

This project uses [`icp-cli`](https://github.com/dfinity/icp-cli) (v1.0.0+) — install via `brew install icp-cli` on macOS.

```bash
# Clean local deploy (network + 5 canisters)
bash scripts/deploy.sh -e local

# Open the frontend
FRONTEND=$(python3 -c "import json; print(json.load(open('.icp/cache/mappings/local.ids.json'))['frontend'])")
open "http://$FRONTEND.localhost:8000"

# IC mainnet (same script, different environment)
bash scripts/deploy.sh -e ic
```

See [`CONTRIBUTING.md`](./CONTRIBUTING.md) for the full local-dev setup (identity, mops, the first-run cycles gotcha) and the common one-shots (redeem, stats, saga journal).

## Project layout

```
icvc-redemption/
├── README.md                  ← this file
├── CLAUDE.md                  ← agent / dev reference (commands, conventions)
├── RECOVERY.md                ← operations runbook (saga states, admin recovery)
│
├── icp.yaml                   ← canister manifest (icp-cli)
├── mops.toml                  ← Motoko deps + toolchain pin
├── canister_ids.json          ← mainnet ids (yofbu-…, zekdo-…, yjeha-…, zdlf2-…)
├── ledger/                    ← pinned WASMs (ICRC-1 ledger, II, asset canister)
│                                  consumed via `type: pre-built` in icp.yaml
│
├── scripts/
│   └── deploy.sh              ← end-to-end deploy: local | ic
│
├── src/
│   ├── redemption/            ← Motoko backend (main canister)
│   │   ├── main.mo            ← actor; redeem flow + admin API + queries
│   │   ├── Types.mo           ← public types: Stats, Errors, InFlightRedemption
│   │   ├── Ledger.mo          ← ICRC-1 / ICRC-2 client interface
│   │   └── Pure.mo            ← pure helpers (calculateIcpPayout, memoFromId, …)
│   │
│   └── frontend/              ← static SPA (no build pipeline)
│       ├── index.html         ← markup only
│       ├── style.css          ← all styles
│       └── js/
│           ├── app.js              ← state, handlers, init
│           ├── idl.js              ← Candid IDL factory (builder fn)
│           ├── config.js.template  ← committed; placeholders for ids+host
│           ├── config.js           ← generated by deploy.sh (gitignored)
│           ├── dfinity-bundle.js   ← entry that re-exports @dfinity/*
│           └── dfinity.js          ← esbuild output (gitignored)
│
├── test/                      ← mops unit tests
│   └── pure.test.mo
│
└── tests/                     ← integration tests
    └── integration.sh         ← shell-driven, runs against the icp local network
```

## Testing

Three layers. Run at least the first two before claiming a change is verified.

```bash
mops test                                          # unit (Motoko, ~0.3 s)
bash tests/integration.sh                          # integration (icp local network)
bash tests/integration.sh --case redeem            # filter
pytest tests/pocketic                              # PocketIC (deterministic time + failure paths)
```

| Layer | Location | Runs against | Covers |
|---|---|---|---|
| Unit | `test/*.test.mo` | Motoko interpreter (no replica) | Pure helpers in `Pure.mo`: payout math, fair-value rate derivation, memo encoding, Nat64 conversion |
| Integration | `tests/integration.sh` | `icp network` local | Auth, financial correctness (balance deltas, not just status), error paths, CallerGuard concurrency, ledger memo + `created_at_time`, pagination, query privacy, upgrade preservation, lock-release on error |
| PocketIC | `tests/pocketic/` | PocketIC replica | Deterministic-time and failure-path scenarios the bash suite can't reach: pool drain, ICP-send failure → refund recovery, DAO tranche funding (see [`CONTRIBUTING.md`](./CONTRIBUTING.md) and the suite's README) |

The integration suite is **idempotent** across runs (state-mutating cases clean up after themselves).

Documented gaps the suite does **not** cover (don't assume regression safety for these): deterministic time control for the lock TTL, forced traps inside redeem, `retryRefund` happy path, `#InsufficientIcpPool`, frontend UI tests. See [`CLAUDE.md`](./CLAUDE.md) for the full coverage map and the "how to add a new case" recipe.

## Phased funding model

The DAO does not deposit the full eventual ICP commitment into the redemption canister in one shot. Funding happens in tranches so a problem caught after the first tranche only puts a slice of the pool at risk, not the whole thing.

**Two on-chain numbers tell the holder-facing story:**

- **ICP distributed** (`Stats.total_icp_distributed`): running total of payouts to holders. Grows when a holder redeems.
- **ICP remaining** (`Stats.icp_remaining`): live `icrc1_balance_of` query against the ICP ledger. Grows when the DAO transfers a new tranche in; shrinks when a holder redeems.

The frontend's progress bar reads **"X distributed of (X + remaining) ICP in pool"**. The denominator is computed live; no admin action is needed between a DAO transfer and the UI updating. After a 10k DAO transfer with 5k of redemptions, that's "5,000 of 10,000". When the DAO sends another 10k, the bar becomes "5,000 of 20,000". As more holders redeem, the bar fills up. Honest, monotonic, no separate counter to maintain.

**The DAO funding step is a plain `icrc1_transfer`** from the DAO treasury to the redemption canister principal; the ICP ledger is the canonical record. No `recordTranche` admin call, no annotated log; if the DAO wants commentary on each transfer, that lives in the DAO's own proposal text.

**The flow for each tranche.**

```
┌──────────────────┐  1. SNS proposal       ┌──────────────────────────┐
│   ICVC DAO       │ ─────────────────────► │  DAO treasury account    │
│ (SNS governance) │                        │  on the ICP ledger       │
└──────────────────┘                        └────────────┬─────────────┘
                                                         │ 2. icrc1_transfer
                                                         │    (executed by DAO
                                                         │     governance)
                                                         ▼
                                            ┌──────────────────────────┐
                                            │   redemption canister    │
                                            │   (icp_remaining grows)  │
                                            └────────────┬─────────────┘
                                                         │ 3. frontend reads
                                                         │    icp_remaining +
                                                         │    distributed
                                                         ▼
                                            ┌──────────────────────────┐
                                            │  progress bar denominator│
                                            │  updates automatically   │
                                            └────────────┬─────────────┘
                                                         │ 4. token holders
                                                         │    redeem against
                                                         │    the new balance
                                                         ▼
                                            ┌──────────────────────────┐
                                            │  watch, wait, evaluate.  │
                                            │  Next tranche after a    │
                                            │  cooling-off period.     │
                                            └──────────────────────────┘
```

**Who does what:**
1. **DAO governance** votes a proposal to transfer `N` ICP from the DAO treasury to the redemption canister principal.
2. The vote, if it passes, executes an ICRC-1 transfer. No canister method is needed; the ICP just shows up and `Stats.icp_remaining` grows on the next `getStats` call.
3. **Frontends and audit tools** see the new pool size immediately: the denominator is computed from `icp_remaining + total_icp_distributed`. No admin step in between.
4. Token holders **redeem** against the larger pool. If a holder tries to redeem more than `icp_remaining`, they get `#InsufficientIcpPool` and can retry after the next tranche.
5. **Wait, watch, and listen.** If complaints surface or a bug is found, `pause()` stops further redemptions. Resolve, `unpause()`, then proceed.
6. **Repeat** until the DAO has finished funding.

**Operational notes** (see [`RECOVERY.md`](./RECOVERY.md) for the runbook):
- The ICP ledger's transaction history is the canonical audit trail for every tranche. Anyone can scan inbound transfers to the redemption canister principal via `icp canister call icp_ledger get_transactions`.
- A redemption that fails with `#InsufficientIcpPool` is benign (no state change); the user retries later.
- Pausing between tranches is the right move if there has been any unusual activity.

## Documentation index

| Doc | Audience | Contents |
|---|---|---|
| [`README.md`](./README.md) | First-time visitor | What it is, architecture, quick start, project layout, doc index |
| [`CONTRIBUTING.md`](./CONTRIBUTING.md) | New contributors | Local dev setup, build/deploy commands, test recipe, PR workflow |
| [`CLAUDE.md`](./CLAUDE.md) | Code authors + AI agents | Architecture conventions, gotchas, test coverage map |
| [`MIGRATIONS.md`](./MIGRATIONS.md) | Operators upgrading mainnet | Routine upgrades, schema-change migration pair pattern, post-deploy checklist |
| [`RECOVERY.md`](./RECOVERY.md) | Operators reconciling failures | Saga journal model, failure scenarios A–F, admin reconciliation flow, controller setup |
| [`TODO.md`](./TODO.md) | Maintainers | Open operational + infrastructure work (go-live cutover, backup admin, cycles monitoring) |

## Audit status

Audited against the [ICP canister-security skill](https://skills.internetcomputer.org/skills/canister-security/SKILL.md). **All HIGH-severity findings are closed.** Remaining open work, all operational or optional: cycles monitoring (L3) and production-tooling polish (real frontend build pipeline, PocketIC harness).

## Tech stack

- **CLI:** [`icp-cli`](https://github.com/dfinity/icp-cli) v1.0.0+. `dfx` is no longer required for deploys (the PocketIC test harness still uses it to provide the `pocket-ic` binary).
- **Backend:** Motoko, `persistent actor class`. `mops` for the base library; `moc 1.8.2` pinned in `mops.toml`'s `[toolchain]` (used by both the test runner and the build step in `icp.yaml`).
- **Token ledgers:** Official `ic-icrc1-ledger.wasm.gz` pinned to IC commit `d4ee25b0865e89d3eaac13a60f0016d5e3296b31`, committed under `ledger/` and consumed via `type: pre-built` in `icp.yaml`.
- **Frontend:** Static SPA, no React/Vite/TypeScript. `index.html` (markup) + `style.css` (styles) + ES-module `js/app.js` + `js/idl.js` + generated `js/config.js`. The `@dfinity/*` packages are pre-bundled to `js/dfinity.js` by esbuild and loaded dynamically. The asset canister itself is the `@dfinity/asset-canister` recipe (icp-cli 1.0.0): `icp deploy` runs the recipe build (esbuild + assemble a clean `dist/`) and its bundled plugin uploads the assets on both `local` and `ic` — no pinned asset WASM, no dfx.
- **Auth:** Internet Identity via `@dfinity/auth-client`.
- **Testing:** `mo:test` for Motoko units; plain bash + `icp canister call` for integration.

See [`CLAUDE.md`](./CLAUDE.md) for the canonical build commands and version notes.

## License and contributions

Licensed under the **Apache License, Version 2.0** (see [`LICENSE`](./LICENSE)). Copyright 2026 DFINITY Stiftung.

**Contribution mode: public, no external code contributions.** Pull requests from outside the DFINITY organization are not accepted and are closed automatically. Bug reports and suggestions are welcome via [issues](https://github.com/dfinity/icvc-redemption/issues). Internal development follows [`CONTRIBUTING.md`](./CONTRIBUTING.md).
