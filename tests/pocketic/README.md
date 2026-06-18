# PocketIC test harness

Deterministic-time integration tests using [PocketIC](https://github.com/dfinity/pocketic).

PocketIC is a Rust-based deterministic IC runtime that lets us:

- install canisters in-process (no replica network);
- advance time programmatically (`pic.advance_time(N)`);
- test the gaps the bash integration suite cannot reach (lock TTL release, forced traps, pool drain).

## Prerequisites

- Python 3.11+ (3.14 tested).
- The PocketIC server binary. Easiest source: `dfx 0.30.2` bundles it at `~/.cache/dfinity/versions/0.30.2/pocket-ic`. Override the autodetected path via `POCKET_IC_BIN=/path/to/pocket-ic`.
- The redemption canister wasm: `icp build` from the repo root produces it at `.icp/cache/artifacts/redemption`.

## Setup

```bash
cd tests/pocketic
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Run

```bash
# From repo root, with the venv active:
icp build                              # ensures the wasm exists
pytest tests/pocketic -v
```

## Current scope

| File | Covers |
|---|---|
| `test_install.py` | Smoke: redemption canister installs cleanly and `listAdmins` returns the init admin. Bogus ledger principals; doesn't exercise the swap flow. |
| `test_insufficient_icp_pool.py` | **Pool-balance pre-flight check.** Install with a tiny ICP pool (0.1 ICP); Alice (pre-funded with ICVC at genesis) approves and redeems an amount that requires ~623 ICP. The canister must return `#InsufficientIcpPool` without touching ledger state. |
| `test_pool_drain_boundary.py` | **Pool boundary precision.** Install with the ICP pool sized to exactly one redeem's `(payout + fee)`. First redeem succeeds (boundary inclusive — `<` not `<=`); second redeem with pool now at 0 must reject with `#InsufficientIcpPool`. |
| `test_redeem_happy_path.py` | **End-to-end swap smoke.** approve → redeem the full flow (Alice pre-funded with ICVC), then verify Alice's ICP balance is exactly `icvc_amount × rate / 1e8` and the canister's balance dropped by payout + fee. Acts as a regression guard for the harness wiring (ledger init args, Candid encoding, fixtures). |
| `test_sequential_redeems.py` | **Stats math over many calls.** 5 sequential redeems, after each one every counter (`total_icvc_redeemed`, `total_icp_distributed`, `total_redemptions`, `icp_remaining`) must match the cumulative expectation. Catches off-by-one drift. |
| `test_dao_tranches.py` | **Phased funding simulation.** The DAO mints ICP into the canister (using the ledger's minting subaccount + DEPLOYER sender), then again. A holder redemption between tranches verifies the balance arithmetic. Also asserts the frontend's progress denominator (`icp_remaining + total_icp_distributed`) is monotonic across tranches (only fees reduce it). |
| `test_icp_send_failure.py` | **ICP-payout failure → saga recovery.** Uses a fault-injecting mock ICP ledger (`mock_icp_ledger.mo`) that passes the pool pre-check then fails the payout *after* the ICVC pull commits — impossible against healthy ledgers. **Trap mode:** the entry is left `#IcpSendPending` (ICP outcome unknown) and `retryRefund` must REFUSE it (the double-spend guard from #48). **`#Err` mode:** the clean failure triggers the in-line refund, returns `#IcpTransferFailed`, and clears the journal. |
| `test_refund_recovery.py` | **Refund/burn retry recovery.** Uses the general `mock_ledger.mo` (runtime-toggleable `icrc1_transfer`) as both ledgers, failing then healing a transfer. Covers: `retryRefund` happy path (`#RefundPending` → refunded), `sweepBurn` flushing a failed inline burn, `getDedupKey` on a real stuck entry, and `forceCloseInFlight` clearing one. |

Shared fixtures live in `conftest.py`: `pic` (fresh PocketIC instance per test), `deployment` (standard 20M ICVC + 1000 ICP), `small_pool_deployment` (20M ICVC + 0.1 ICP), and `make_faulty_icp_deployment(...)` (real ICVC + the mock ICP ledger). Ledger init args are built in `ledgers.py`; the mock ledger is compiled on demand from `mock_icp_ledger.mo`.

## Gaps that cannot be closed by PocketIC alone

Two of the documented bash-suite gaps need changes outside this directory:

- **Redeem lock TTL (60s)**: the canister's `try/finally` block in `redeem` always releases the lock unless the canister is upgraded mid-message (in which case the transient lock state is wiped anyway by the upgrade — also fine). To deterministically reach a state where a lock is acquired and not released within the TTL window, the canister would need a debug-mode method like `forceAcquireLockForTest` gated behind a compile-time flag. That adds test-only code to the production canister, which the team has deliberately avoided. **Recommendation:** do not close this gap unless the canister gains a debug build target. The TTL's behaviour is testable by manual code inspection (the math is one line in `tryAcquireRedeemLock`).
- **`retryRefund` happy path**: needs BOTH the ICP send AND the in-flow ICVC refund to fail in the same redeem call, so the saga entry survives in `#RefundPending`. Stopping just the ICP ledger isn't enough — the in-flow refund (which uses the still-running ICVC ledger) succeeds and cleans up the entry. Stopping BOTH means the *initial* `icrc2_transfer_from` also fails, so the saga entry is never written. The fix would be a helper canister that proxies ICP-ledger calls and can be told to misbehave on a specific message, or PocketIC-level network manipulation (`set_subnet_to_unhealthy` or similar — not in the Python client as of v3.1.2). **Recommendation:** revisit once PocketIC exposes finer-grained subnet/canister-health controls in its Python bindings.

## Why not extend `tests/integration.sh`?

That suite runs against a real replica with wall-clock time. Adding "advance time 70s" tests there would mean literally waiting 70s, which doesn't scale. PocketIC's deterministic time advance is the reason this directory exists.
