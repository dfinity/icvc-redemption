# Recovery Runbook

How to handle redemption failures, trapped canister states, and partial flows.

The redemption canister is intentionally **not** a black hole. Admin (any principal in the allowlist, seeded from `init.admin` on first install) plays an active role in recovery: the canister auto-handles the common failure paths, journals the rare ones, and exposes admin tools to reconcile anything that gets stuck.

---

## 1. Architecture: the saga journal

The redemption flow consists of two ledger transfers separated by an `await`. Anywhere a trap, upgrade, or transient ledger error can land between them, we need a way to recover.

### `inFlight` buffer

A persistent buffer of `InFlightRedemption` records. Each record has a status that tells admin what (if anything) needs to happen:

| Status | Meaning | Ledger state | Recovery action |
|---|---|---|---|
| `#Started` | Journal entry written; the `transfer_from` reply was not processed | Pull may or may not have executed | Reconcile via the dedup key (below); then `forceCloseInFlight` (no pull) or treat as `#IcpSendPending` (pull executed) |
| `#IcvcPulled { icvc_tx_id }` | Transient/legacy "pull done" state (superseded by `#IcpSendPending` for new redeems) | Pulled | Treat like `#IcpSendPending` |
| `#IcpSendPending { icvc_tx_id }` | ICVC pulled; ICP send was in flight and its **outcome is unknown** (the reply was lost to a trap/upgrade) | Pulled; **ICP may or may not have been sent** | **Reconcile first** (below). If ICP *was* sent → `forceCloseInFlight(id)`. If ICP was *not* sent → `forceRefund(id)`. **Never `retryRefund` blindly — it could double-pay.** |
| `#RefundPending { icvc_tx_id; icp_error; refund_error }` | ICP send failed (**known** — clean `#Err`) and the auto-refund also failed | Pulled, no refund | `retryRefund(id)` once the ledger is healthy (safe: ICP definitely did not go out) |

> **Why `#IcpSendPending` must not be blind-refunded:** a *clean* ICP failure never lands here — it goes straight to `#RefundPending`. So an entry that *persists* as `#IcpSendPending` only happens when the ICP-transfer reply was lost (trap/upgrade after the call committed), meaning the payout **may have settled**. Refunding without checking would pay the user twice. `retryRefund` enforces this — it refuses `#IcpSendPending`/`#IcvcPulled` and only auto-refunds `#RefundPending`.
>
> **Reconciling an `#IcpSendPending` entry:** `getDedupKey(id)` returns its `created_at_time`; scan the **ICP** ledger for an `icrc1_transfer` from the canister to the user with memo `redemption-<id>` and that `created_at_time`. Present → ICP settled → `forceCloseInFlight(id)`. Absent → ICP did not go out → `forceRefund(id)` (refunds with a fresh timestamp; only safe *after* this check).

Entries are removed on clean completion. Survives canister upgrades. Each entry also carries `started_at` (creation), `last_updated` (last status transition / refund attempt), and `refund_attempts` (how many refund transfers have been issued) — use these to gauge how long and how hard an entry has been stuck.

### Dedup key (embedded in saga journal entries)

Each `InFlightRedemption` carries its own `icvc_dedup_created_at : Nat64`: the `created_at_time` we passed to `icrc2_transfer_from`. Together with the memo `"redemption-<id>"`, this is the ICRC-1 ledger's dedup key, so a reconciliation tool can query the ledger and determine whether a `#Started` entry's pull actually executed. The legacy parallel `dedupKeys` map was folded into the saga journal in PR #10 (saga consolidation).

Exposed via `getDedupKey(id)` (admin-only).

### Per-caller reentrancy lock

`pendingRedemptions : HashMap<Principal, Int>`. Held for the duration of a single `redeem` call. Released by a `finally` block, so even if the body traps the lock is freed. A 60-second TTL is the backstop if `finally` does not run (e.g., a hard crash).

This is in-memory only — upgrades clear it, which is correct (in-flight messages do not survive an upgrade).

### Ingress message inspection

`system func inspect(...)` (the `canister_inspect_message` hook) runs on a single replica before an ingress update is accepted, so it can reject a call **before** it consumes cycles or goes through consensus. It drops the *update* methods that the canister body would reject for an **anonymous** caller anyway — `redeem`, `faucet`, `retryRefund`, `sweepBurn`, `forceCloseInFlight`, `forceRefund`, `pause`, `unpause`, `addAdmin`, `removeAdmin`. Queries pass through unfiltered so their bodies can still return their normal diagnostic error variants (`#NotAuthorized`, etc.), and `getStats` stays anonymous-readable because the frontend depends on it.

This is a spam/cost guard, not the authorization boundary — every method still enforces its own auth in the body. When adding a new update method, add it to **both** the `inspect` message variant and (if it should reject anonymous callers) the anonymous-drop switch, or it will be reachable by anonymous ingress.

---

## 2. Normal operation

```
                                                                ┌──────────────┐
                                                                │ remove entry │
                                                                │  remove key  │
                                                                └──────▲───────┘
                                                                       │ ICP send Ok
       acquire lock                                                    │
            │                                                          │
            ▼          write #Started                          ┌───────┴───────┐
 ┌──────────────────┐  record dedup key   ┌───────────────┐    │  switch on    │
 │ early checks     │────────────────────►│  transfer_from│───►│  icrc1_       │
 │ (paused/min/etc) │                     │  (icvc_ledger)│    │  transfer     │
 └──────────────────┘                     └───────────────┘    │  result       │
                                              │  Err            └───────┬───────┘
                                              ▼                         │ ICP send Err
                                       remove entry                     │
                                       remove key                       ▼
                                       return                ┌────────────────────┐
                                                             │  attempt in-line   │
                                                             │  refund            │
                                                             └─────────┬──────────┘
                                                                  Ok ──┤── Err
                                                                       │
                                                                       ▼
                                                            set #RefundPending
                                                            return #NeedsRefund(id)
```

Status transitions for the happy path: `#Started` → `#IcvcPulled` → (entry removed). The user is unaware that the journal exists.

---

## 3. Failure scenarios and recovery

### Scenario A: ICP send failed, auto-refund succeeded

The canister handles this with no admin involvement.

- Call returns `#err(#IcpTransferFailed("..."))`.
- Journal entry is removed; user has their ICVC back (minus a transfer fee).

**Admin action:** none.

---

### Scenario B: ICP send failed AND auto-refund also failed

The canister cannot complete the round trip, journals the failure, and waits.

- Call returns `#err(#NeedsRefund(id))`.
- Entry remains in `#RefundPending` with both error messages stored.

**User action:** call `retryRefund(id)` once the ledger has recovered.

**Admin action:**
- Same `retryRefund(id)` works for admin on the user's behalf.
- If the refund keeps failing for a structural reason (e.g., ICVC ledger permanently lost the funds), admin can `forceCloseInFlight(id)` after manually compensating the user — but that should be the last resort and should be recorded operationally.

---

### Scenario C: Canister upgrade or trap after `#IcvcPulled` was written

The ICP send was sent but the canister never observed the response — typically because an upgrade happened mid-flow, or a trap propagated up before the result was processed.

- The user's call returns an error (or times out client-side).
- After the canister recovers, admin sees a `#IcvcPulled` entry in `getInFlight()`.

**Discovery:**
```bash
icp canister call -e ic redemption getInFlight '()' --query
```
Look for entries with `status = variant { IcvcPulled = record { icvc_tx_id = ... } }` and an old `started_at`.

**Recovery:**
1. **Verify the ICP send did not succeed silently.** Use the ICP ledger transaction history to check whether a transfer with memo `"redemption-<id>"` from the canister to the user is present:
   ```bash
   # Get the dedup key so we know what window to scan
   icp canister call -e ic redemption getDedupKey '(<ID> : nat)' --query
   # Inspect recent ICP ledger txs
   icp canister call -e ic icp_ledger get_transactions '(record { start = <START> : nat; length = 100 : nat })' --query
   ```
2. **If no matching ICP transfer exists** (the most common case): call `retryRefund(<id>)`. The canister sends the ICVC back to the user, journal entry is removed.
3. **If a matching ICP transfer DOES exist** (rare — means the ledger committed but we never wrote the success record): the user already got their ICP. Admin should `forceCloseInFlight(<id>)` to clean up the journal without double-paying. Update the redemption stats off-chain if accurate accounting matters.

---

### Scenario D: Canister upgrade or trap between writing `#Started` and writing `#IcvcPulled`

This is the narrowest gap: a trap landed inside the `icrc2_transfer_from` callback before the canister got to flip the status. The ledger may or may not have processed the pull.

- Journal entry status is `#Started`.
- `icvc_tx_id` is unknown.

**Discovery:** stale `#Started` entries in `getInFlight()` (older than ~1 minute is a strong signal).

**Recovery:**
1. **Get the dedup key:**
   ```bash
   icp canister call -e ic redemption getDedupKey '(<ID> : nat)' --query
   ```
2. **Query the ICVC ledger transactions** for a transfer with memo `"redemption-<id>"` from the user to the canister, matching the `created_at_time` from the dedup key:
   ```bash
   icp canister call -e ic icvc_ledger get_transactions '(record { start = 0 : nat; length = 1000 : nat })' --query
   ```
   The exact start index depends on how busy the ledger is; iterate or use archived ranges as needed.
3. **If a matching transfer is found:** the pull executed. The user is owed a refund. **Currently there is no API to transition `#Started → #IcvcPulled` directly.** Admin workaround:
   - Send the refund manually:
     ```bash
     echo y | icp canister call -e ic icvc_ledger icrc1_transfer '(record {
       from_subaccount = null;
       to = record { owner = principal "<USER>"; subaccount = null };
       amount = <AMOUNT_MINUS_FEE> : nat;
       fee = opt 10_000 : nat;
       memo = opt blob "redemption-<ID>";
       created_at_time = null;
     })'
     ```
   - Then `forceCloseInFlight(<id>)` to clean up the journal.
4. **If no matching transfer is found:** the pull did not execute. No ledger state change. Call `forceCloseInFlight(<id>)` to drop the entry.

> **Closing this gap further** is a future-phase improvement: wire ICRC-3 `get_transactions` into the canister so it can do step 2 internally, plus a `reconcileStarted(id)` admin method that automates step 3/4. The data needed (the dedup key inside each `InFlightRedemption`) is already persisted.

---

### Scenario E: Canister cycles freeze

The canister runs out of cycles and stops processing. Redemptions hang and `getStats` becomes unreachable.

**Recovery:**
1. Top up cycles via the cycles ledger or your wallet.
2. Once the canister is responsive, run the discovery from Scenarios C and D — any in-flight entries from before the freeze need triage.

**Prevention:**
- Keep at least 90 days of cycles at all times. The freezing threshold is canister-configurable (`icp canister settings update <ID> --freezing-threshold <SECONDS> -e ic`).
- Monitor balance via the cycles ledger or a separate observability canister.

---

### Scenario F: `retryRefund` returns `TooOld`

The refund's `created_at_time` is pinned to the journal entry's `icvc_dedup_created_at` (set when the redeem started) so that retries are caught by the ICRC-1 ledger's dedup window. That window is ~24h. A retry submitted more than 24h after the original redeem returns `Err(TooOld)`.

This is most likely to hit `#IcvcPulled` orphans (upgrade- or trap-orphaned entries the user has no visibility into) where admin notices days later. `#RefundPending` entries can also hit it if the user takes >24h to click "Get refund" once the recovery UI lands.

**Recovery:**
1. **Check whether an earlier refund attempt actually committed.** Look up the entry's dedup key:
   ```bash
   icp canister call -e ic redemption getDedupKey '(<ID> : nat)' --query
   ```
   Scan the ICVC ledger transactions for an outbound transfer from the canister to the user with memo `"redemption-<ID>"`:
   ```bash
   icp canister call -e ic icvc_ledger get_transactions '(record { start = <START> : nat; length = 100 : nat })' --query
   ```
2. **If a matching refund tx exists:** the user has been refunded. Call `forceCloseInFlight(<id>)` to clear the journal entry.
3. **If no matching refund tx exists:** the payout/refund never settled. Call `forceRefund(<id>)` — it refunds with a *fresh* `created_at_time`, bypassing the expired dedup window that makes `retryRefund` return `TooOld`. (Only safe because step 1 confirmed nothing settled; a fresh timestamp has no dedup protection.)

**Prevention:** triage `getInFlight()` daily during the wind-down so no `#IcvcPulled` or `#RefundPending` entry sits past the 24h dedup window unnoticed.

---

## 4. Admin API reference

| Method | Type | Purpose |
|---|---|---|
| `getRedemptionLog(offset, limit)` | query (public) | **Incident triage view.** Every redemption — completed *and* in-flight — in one paginated list (newest first) with a uniform status. A `#IcvcPulled` row (icvc_tx_id set, icp_tx_id null) is "ICVC received, ICP not distributed" |
| `getInFlight()` | query (public) | Full list of in-flight entries with status (auditable by anyone) |
| `getPendingBurns()` | query (public) | Redeemed-but-unburned queue (entries `sweepBurn` would retry) |
| `getMyInFlight()` | query | Caller's own in-flight entries (user-facing) |
| `getDedupKey(id)` | query (admin) | `created_at_time` used on the original `transfer_from`, for ledger lookup |
| `getStats()` | update | Pool balance, redemption counts, paused flag |
| `retryRefund(id)` | update | Retry refund for `#IcvcPulled` or `#RefundPending` entries (caller must be the user or admin) |
| `forceCloseInFlight(id)` | update (admin) | Drop an entry without refunding — use after manual reconciliation |
| `forceRefund(id)` | update (admin) | Refund a stuck entry with a **fresh** `created_at_time` (bypasses the `TooOld` dedup window and the `retryRefund` `#IcpSendPending` refusal). Only after reconciling that no payout/refund settled — no dedup protection |
| `sweepBurn()` | update (admin) | Flush redeemed-but-unburned ICVC (`icvc_pending_burn` > 0). Retries each pending burn with its original dedup tuple, so a lost-response burn returns `Duplicate` rather than double-burning. Allowed while paused. Returns the ICVC burned this call |
| `forceBurn()` | update (admin) | Like `sweepBurn` but with a **fresh** `created_at_time`, for burns stuck past the `TooOld` dedup window. No dedup protection — only after confirming on the ICVC ledger (memo `burn-<id>`) that the original burn never settled, else it double-burns |
| `pause()` / `unpause()` | update (admin) | Stop / resume accepting new redemptions |
| `getExchangeRate()` | query (public) | Read the immutable exchange rate (set at install, no runtime setter) |
| `addAdmin(p)` | update (admin) | Add `p` to the admin allowlist |
| `removeAdmin(p)` | update (admin) | Remove `p`; refuses to remove the last admin |
| `listAdmins()` | query (public) | Show every principal currently authorised |

Ledger inspection happens via the ICRC-1 ledger's own API, **not** through the redemption canister:

```bash
# Recent transactions on the ICVC ledger
icp canister call -e ic icvc_ledger get_transactions '(record { start = <N> : nat; length = <M> : nat })' --query

# Same for ICP ledger
icp canister call -e ic icp_ledger get_transactions '(record { start = <N> : nat; length = <M> : nat })' --query

# Balance check
icp canister call -e ic icp_ledger icrc1_balance_of '(record { owner = principal "<CANISTER>"; subaccount = null })' --query
```

---

## 5. Operational best practices

1. **Pause before upgrading.** `echo y | icp canister call -e ic redemption pause '()'` → wait until `getInFlight` is empty → deploy → `echo y | icp canister call -e ic redemption unpause '()'`. This avoids creating `#Started` / `#IcvcPulled` orphans.
2. **Monitor the journal.** Any entry whose `started_at` is more than a few minutes old needs attention. A scheduled job that paginates `getInFlight()` and alerts on stale entries is a small but high-value addition.
3. **Cycles monitoring.** Keep ≥ 90 days of headroom; never let the canister freeze.
4. **Backup admin and backup controller.** Two distinct layers, both needed:
   - **Admin allowlist** (in-canister, set via `addAdmin`): authorises calls to `pause`, `retryRefund`, `forceCloseInFlight`, etc. The current set is visible via `listAdmins`.
   - **Canister controllers** (IC platform-level, set via `icp canister settings update`): authorises code upgrades, cycles top-ups, and stop/delete. If the only controller is lost, the canister cannot be upgraded.

   For both: add at least one **independent** backup principal before going to production. The admin allowlist guards against operational lockout; the controller list guards against complete loss of the canister.
5. **Treat `forceCloseInFlight` as a last resort.** It can permanently lose user funds if invoked while the ledger state actually owes the user. Always verify on-chain before calling it. Consider recording every invocation in an off-chain log.
6. **Phased funding rhythm.** Each tranche is a small, reversible commitment. Follow the cadence:
   1. DAO proposal passes; the DAO treasury executes an `icrc1_transfer` to the redemption canister principal.
   2. Confirm the inbound transfer on the ICP ledger: `icp canister call -e ic icp_ledger icrc1_balance_of '(record { owner = principal "<REDEMPTION>"; subaccount = null })' --query`. `Stats.icp_remaining` (and therefore the frontend's "X distributed of Y in pool" denominator) updates automatically.
   3. Watch redemption activity for the cooling-off window agreed with the DAO. Any unusual pattern → `pause()`, investigate, then `unpause()`.
   4. Only after step 3 is satisfied: propose the next tranche.

---

## 6. Admin rotation and backup setup

### In-canister admin allowlist

```bash
# Inspect current admins (public query)
icp canister call -e ic redemption listAdmins '()' --query

# Grant admin to a new principal
echo y | icp canister call -e ic redemption addAdmin '(principal "<NEW_PRINCIPAL>")'

# Revoke admin
echo y | icp canister call -e ic redemption removeAdmin '(principal "<OLD_PRINCIPAL>")'
```

`removeAdmin` refuses to leave the list empty. Add a backup admin **before** removing the original.

Recommended rotation flow:
1. `addAdmin(new)` from the current admin.
2. Verify the new admin can call a low-risk method (e.g., `pause` then `unpause`).
3. `removeAdmin(old)` if the original principal is being retired.

### Canister controllers (IC platform-level)

Controllers can install code, top up cycles, and stop/delete the canister. They are separate from the admin allowlist. View and manage them with:

```bash
# Show controllers (and other canister settings)
icp canister status redemption -e ic

# Add a backup controller (idempotent)
icp canister settings update redemption -e ic \
    --add-controller <BACKUP_PRINCIPAL>

# Remove a controller (DANGEROUS if it leaves the canister un-upgradeable)
icp canister settings update redemption -e ic \
    --remove-controller <PRINCIPAL>
```

Good candidates for a backup controller:
- A hardware-key principal held by a separate operator.
- An NNS / SNS canister, if the wind-down is under governance control.
- A multi-sig or threshold-key canister.

Avoid leaving the canister with a single controller in production — losing that key means the canister can never be upgraded again, and there is **no on-chain recovery path** for that case.

---

## 7. What the canister deliberately does *not* do

- **No automatic ICRC-3 reconciliation.** Admin must verify ledger state before crediting any refund for a `#Started` entry. This avoids accidental double-refunds where the in-line refund actually succeeded but our journal lost track.
- **No two-step admin transfer.** `addAdmin` / `removeAdmin` apply immediately; there is no propose / confirm round-trip. For higher-stakes deployments, do `addAdmin` followed by a separate verification call from the new admin before any `removeAdmin`.
- **No frontend-driven recovery (yet).** All recovery actions are via `icp` or a thin admin tool. The current SPA does **not** wire `retryRefund`/`getMyInFlight` — a user-facing "Get refund" flow is still future work (see Scenario F's "once the recovery UI lands"), so today even the user's own refund retries go through an operator.

The design accepts that admin is in the loop for non-trivial recovery. The canister's job is to **journal enough that recovery is always possible**, not to be fully autonomous.
