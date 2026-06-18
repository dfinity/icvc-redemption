# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

Prototype ICVC redemption canister for winding down ICVC DAO on the Internet Computer: token holders swap ICVC for ICP at a fair-value rate derived from the DAO treasury's backing. The rate is fixed in the deployed wasm and changes only via upgrade.

**Prod prep in progress** — `main` is being readied for a real-value deployment: the **faucet has been removed**, and a prod deploy points at the real ICVC ledger (`m6xut-mqaaa-aaaaq-aadua-cai`) and the NNS ICP ledger (`ryjl3-tyaaa-aaaaa-aaaba-cai`). The original **play** deployment (canisters `yofbu`/`zdlf2`, tagged `play-v1`) still runs against our own ICRC-1 ledger copies, *not* the production tokens.

See [`README.md`](./README.md) for the full overview, architecture diagram, project layout, and tech stack. This file is the agent / code-author reference: the parts not duplicated elsewhere are the gotchas in "Important Details" and the test coverage map below.

## Architecture

See [`README.md`](./README.md#architecture) for the canister topology, architecture diagram, swap flow, and full project layout. Agent-relevant source map for the main canister (`src/redemption/`):

- `main.mo` — actor entry, lock, redeem flow + extracted helpers (`pullIcvc`, `sendIcp`, `attemptRefundAndJournal`), admin API, queries
- `Types.mo` — public types (`Stats`, `RedemptionError`, `InFlightRedemption`, `FailedRefund`)
- `Ledger.mo` — ICRC-1/2 client interface
- `Pure.mo` — pure helpers extracted from the actor for unit testing (`calculateIcpPayout`, `memoFromId`, `intToNat64`)

Swap flow (one-line): approve → `redeem` pulls ICVC via `icrc2_transfer_from` → sends ICP via `icrc1_transfer` → **burns the pulled ICVC** (last step, success-only, so a failed swap is still refundable). Every step is journalled; see `RECOVERY.md` for the state machine.

## Build & Deploy

Build/deploy commands and one-shot recipes live in [`CONTRIBUTING.md`](./CONTRIBUTING.md). The relevant entry points:

- `bash scripts/deploy.sh -e local` — local network + all canisters
- `bash scripts/deploy.sh -e ic` — mainnet upgrade (builds the redemption WASM reproducibly via `Dockerfile.build` + hash-gate; frontend syncs via the `@dfinity/asset-canister` recipe — needs Docker, no dfx)
- `icp build` — compile Motoko + materialise pre-built WASMs from `icp.yaml`
- `mops test` — unit tests; `bash tests/integration.sh` — integration suite

For stable-schema changes (adding/removing a stable variable) follow [`MIGRATIONS.md`](./MIGRATIONS.md): either ship a `Migration.mo` in a paired-PR pattern, or use `--mode reinstall` if the canister state is replaceable.

## Tech Stack

See [`README.md`](./README.md#tech-stack) for the full stack (icp-cli ≥ 1.0.0, Motoko/mops with `moc 1.8.2` pinned, pinned ledger WASM, frontend via the `@dfinity/asset-canister` recipe with esbuild-bundled `@dfinity/*`, II auth). Build/deploy commands live in [`CONTRIBUTING.md`](./CONTRIBUTING.md). The agent-relevant gotchas (e.g. the `persistent actor class` requirement and icp-cli's stricter Candid literal parsing) are in "Important Details" below.

## Important Details

- Exchange rate is in e8s: `5_758_856` means 0.05758856 ICP per 1 ICVC (the current fair-value-derived rate, 2026-06-18 COB; see the H2 note below)
- All token amounts are in e8s (10^8 = 1 token)
- Minting accounts use dedicated subaccounts (not default accounts) to avoid accidental burns when transferring to/from the deployer
- The **faucet was removed** (prod prep): no `faucet` method, cooldown, or ICVC pre-funding. The redemption canister is funded with ICP for payouts (mainnet: by the DAO treasury; local: `initial_balances`); it holds no ICVC reserve (it pulls + burns ICVC per redeem). Local/test users get ICVC from ledger `initial_balances`/minting, not a faucet
- `persistent actor class` syntax required for Motoko on moc ≥ 0.10 (with `transient` for non-stable lets)
- `system func inspect` (`canister_inspect_message`) drops anonymous *update* calls at ingress before they cost cycles/consensus; queries pass through (so they return their normal error variants) and `getStats` stays anonymous-readable. It is a cost/spam guard, **not** the auth boundary (every method re-checks auth in its body). When you add an update method, add it to **both** the `inspect` message variant and the anonymous-drop switch, or anonymous ingress can reach it. See `RECOVERY.md` §1
- Init args to ledger canisters need explicit Candid type annotations (`10_000 : nat`, `8 : nat8`, `1000 : nat64`, etc.) — icp-cli's parser is stricter than dfx's and rejects implicitly-typed numeric literals against `nat8`/`nat16`/`nat64` fields
- `seedData`, `closeSeeding`, `isSeedingClosed` no longer exist (removed once mainnet was seeded). Fresh local deploys start with an empty redemption history; the deployer is pre-funded with ICVC, so `redeem` (after `icrc2_approve`) populates it during testing
- The exchange rate is **derived and immutable-except-by-upgrade** (H2). It is computed by `fairValueRate()` from the fair-value backing constants in `main.mo` (`ICVC_TOTAL_SUPPLY_E8S`, `TREASURY_ICP_E8S`, `TREASURY_NICP_E8S`, `NICP_PER_ICP_E8S`; the pure math is `Pure.computeFairValueRate`): `(treasury ICP + treasury nICP valued in ICP) / total ICVC supply`. The four inputs are pulled from on-chain truth (ICVC ledger total supply, ICP + nICP balances of the SNS governance canister `ntzq5-…`, and WaterNeuron `get_info.exchange_rate` for the nICP→ICP fair value) and baked in as constants with a `FAIR_VALUE_INPUTS_RECORDED_AT_NS` timestamp. The derived value is held in stable `var exchange_rate_e8s`, computed on install and **recomputed in `postupgrade`** so bumping the constants takes effect on upgrade. There is no runtime setter — changing the rate means an upgrade that edits the constants, visible on-chain via the module hash. Do not re-introduce a `setExchangeRate` method. `getFairValueInputs()` exposes the inputs + derived intermediates for verification (anonymous-readable, like `getStats`). Note: the inputs are transient constants and the rate stays a stable `var`, so this carries **no stable-schema change** (no `Migration.mo` needed)
- Redeemed ICVC is **burned** (sent to the ICVC ledger's minting account) as the final step of a successful `redeem` — destroyed, not held or recycled. The burn is best-effort and never fails the redeem (the user already has their ICP); it is **dedup-safe** (pinned `created_at_time` + `burn-<id>` memo, `Duplicate` treated as success) so a lost response can't double-burn. A failed inline burn parks `(id, amount, createdAt)` in `pendingBurns`; the admin `sweepBurn()` retries them with the same dedup tuple. Invariant: `totalIcvcRedeemed = totalIcvcBurned + sum(pendingBurns.amount)`; `getStats` surfaces `total_icvc_burned` and `icvc_pending_burn`. Burning the exact redeemed `amount` (not the raw balance) is robust to any other ICVC the canister holds. Do NOT move the burn earlier than the ICP send — it would destroy ICVC that a failed swap still needs to refund
- `InFlightRedemption.icvc_dedup_created_at` is the per-redemption ICRC-1 dedup timestamp. It is reused by **all** refund paths for that entry (in-line refund + every `retryRefund` call), so the ledger's dedup window catches duplicates and a lost response can't cause a double-refund. Do not repurpose this field, do not regenerate it on retry. The dedup window is ~24h from this timestamp; see `RECOVERY.md` Scenario F for the post-window failure mode
- Saga states distinguish a **known** ICP failure from an **unknown** one, and `retryRefund` must respect this. The journal goes `#Started` → `#IcpSendPending` (set *before* the `icrc1_transfer` await, so it's the committed state while the ICP send is in flight) → settled/removed or `#RefundPending`. A *clean* ICP failure (`sendIcp` returns `#Err`) is handled in-line and lands in `#RefundPending` (ICP definitely did not go out → safe to `retryRefund`). A `#IcpSendPending`/`#IcvcPulled` entry that **persists** means the ICP reply was lost (trap/upgrade after the call committed) → the payout **may have settled**, so `retryRefund` refuses it (blind refund could double-pay) and the operator must reconcile the ICP ledger first (`getDedupKey` + memo `redemption-<id>`). Do not "simplify" `retryRefund` to refund `#IcpSendPending`. See `RECOVERY.md`
- Pool accounting reads two numbers off on-chain truth (see "Phased funding model" in `README.md`): `total_icp_distributed` and `icp_remaining` (live `icrc1_balance_of`). The frontend renders these as "X distributed of (X + remaining) ICP in pool"; the denominator is computed in the browser. No `recordTranche` / `icp_committed` counter is maintained, so a DAO `icrc1_transfer` is the only step needed to update the displayed pool size

## Testing

Three layers (unit, integration, and a PocketIC suite under `tests/pocketic/`). Run at least the unit + integration layers before claiming a change is verified.

```bash
mops test                                          # unit (Motoko, ~0.3 s)
bash tests/integration.sh                          # integration (~30 s)
bash tests/integration.sh --case redeem            # filter by substring
```

**Unit layer — `test/*.test.mo` via `mops test`.**

- Runs against the Motoko interpreter only; no replica required.
- Tests pure helpers in `src/redemption/Pure.mo`: `calculateIcpPayout`, `memoFromId`, `intToNat64`. Anything actor-stateful or async cannot live in `Pure.mo`.
- Adding a new unit test: add a `test/<name>.test.mo` with `import { test } "mo:test";` and one `test("description", func() { assert ...; });` per case. Mind the parser quirk: `assert x == (y : T);` needs parens around the typed literal.
- `mops.toml` pins `moc = "1.8.2"` in `[toolchain]` so `mops test` has a compiler independent of dfx's bundled moc.

**Integration layer — `tests/integration.sh`.**

- Runs against the icp-cli local network. Assumes `bash scripts/deploy.sh -e local` has been run.
- Idempotent across runs (state-mutating tests clean up after themselves).
- Auto-creates a `test-admin` icp identity for two-principal scenarios; skipped if it already exists.
- Helpers: `icp_call NAME METHOD ARGS` (update, pipes `y`), `icp_call_id IDENTITY NAME METHOD ARGS` (update as a specific identity).
- Coverage map (use this when judging whether existing tests already cover a change):

| Concern | Cases |
|---|---|
| Auth surface | listAdmins, anonymous reject, admin-only methods, addAdmin/removeAdmin/lockout |
| CallerGuard | same-caller concurrent reject, multi-principal parallel, lock release after error path |
| Saga journal | empty after success, public inspection (`getInFlight`/`getPendingBurns` are public, anonymous-readable), retryRefund error on unknown id |
| Error paths | `#BelowMinimum`, `#Paused`, `#TransferFromFailed`, anonymous, unknown ids |
| Financial correctness | redeem balance delta, `total_icvc_redeemed` increment, redeem burns ICVC (`total_icvc_burned` += amount, supply drops, canister balance unchanged), `sweepBurn` admin no-op |
| Ledger integration | memo and `created_at_time` present on underlying ICRC tx |
| Queries | `getRedemptionHistory` pagination, `getRedemptionLog` unified+public, `getUserRedemptions` privacy, `getExchangeRate` derived-rate check, `getFairValueInputs` breakdown, `setExchangeRate`-removed (H2) guard |
| Upgrade safety | admin allowlist + redemption count preserved through upgrade |

**Gaps the *bash* suite does NOT cover** (most are covered by the PocketIC suite — see `tests/pocketic/`):

- `#InsufficientIcpPool` / pool drain — **covered by PocketIC** (`test_insufficient_icp_pool`, `test_pool_drain_boundary`).
- ICP-payout failure → refund recovery, and the `#IcpSendPending` double-spend guard — **covered by PocketIC** (`test_icp_send_failure`, via a fault-injecting mock ICP ledger).
- `retryRefund` happy path (`#RefundPending` → refunded), `sweepBurn` flushing a failed inline burn, `getDedupKey` on a real stuck entry, and `forceCloseInFlight` clearing one — **covered by PocketIC** (`test_refund_recovery`, via the general toggleable `mock_ledger.mo` as both ledgers).

**Still uncovered anywhere** (do not assume regression-safety):

- A trap inside the canister's *own* redeem code (not a downstream ledger trap) — would need a test-only trap hook in the canister.
- Subnet queue pressure / stress; frontend UI tests (no browser harness).
- **Concurrent interleaving** (e.g. a `redeem` appending to `pendingBurns` during a `sweepBurn`/`forceBurn` await — the TOCTOU class). `sweepBurn`/`forceBurn` are written to be safe (they reconcile against the *current* `pendingBurns` by removing burned ids, never overwriting with a stale snapshot), but that safety is **not** stably regression-tested. The PocketIC Python harness has only blocking `update_call` (no `submit_call`), so the interleave can't be driven via two ingress messages. It *can* be forced via a re-entrant mock ledger (mock calls `redeem` mid-burn), and doing so confirmed the pre-fix bug is real — but whether the dropped-entry race manifests depends on PocketIC's round scheduling (the same re-entrant test flip-flops pass/fail on the buggy wasm), so any such test is flaky and not worth committing. The fix is correct by construction.

**Adding a new integration case.** Write a `case_<name>() { ... }` function that returns 0 on success and uses `expect_contains` for substring assertions. Wire it into the runner block at the bottom of `tests/integration.sh`. Quirks to remember:

- `icp canister call` pretty-prints `(variant {` and the variant name on separate lines; substring assertions should target unique tokens like `ok = record`, not `"variant { ok"`.
- Anonymous calls can't fetch the canister's candid metadata, so the response comes back **hash-encoded** (e.g. `5_048_165` is `err`, `24_860` is `ok`, `2_102_411_630` is `NotAuthorized`). Tests that exercise anonymous callers must accept either the symbolic OR the hash form (see `case_anonymous_redeem_rejected` for the pattern).
- Methods that take no args still need an explicit `'()'` for anonymous callers — without candid, icp-cli can't infer "no args".

## Operations

- **Recovery runbook**: see `RECOVERY.md` for the saga journal model, failure-scenario procedures, and admin-side reconciliation steps. The canister is deliberately not autonomous on the edge cases — admin plays an active role.
