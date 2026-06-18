# Migrations Playbook

How to safely upgrade the mainnet redemption canister, with and without stable-schema changes.

This doc complements [`RECOVERY.md`](./RECOVERY.md) (admin recovery) and [`README.md`](./README.md) (project overview). The audience is whoever is about to run `bash scripts/deploy.sh -e ic`.

---

## TL;DR

| Situation | Command | What happens |
|---|---|---|
| Routine code change, no stable-schema change | `bash scripts/deploy.sh -e ic` | `--mode upgrade` on redemption + frontend. Ledgers untouched. State preserved. |
| Stable-schema change that you DO want to migrate (production canister with real value) | First land a `Migration.mo` PR (see §3), then `bash scripts/deploy.sh -e ic` | Motoko's migration function folds the old shape into the new one on the upgrade. State preserved. Removal of the migration is a paired follow-up PR. |
| Stable-schema change that you DON'T need to migrate (play-token canister; state is replaceable) | `bash scripts/deploy.sh -e ic --reinstall-redemption` | Redemption canister state is **wiped**. Ledgers untouched. |

> The script never touches the mainnet **ledger** canisters. Their balances (20M ICVC + 781,458 ICP) are the real value here, and they're tracked on the ledger canisters, not inside redemption. Reinstalling the redemption canister does NOT wipe those balances.

---

## 1. Preconditions before any mainnet deploy

1. **Controller authority.** Your `icp` identity must already be a controller on the mainnet canisters. The original deploy used a dfx identity; import its PEM into icp-cli:

   ```bash
   # one-time
   dfx identity export <original-name> > /tmp/original.pem
   icp identity import --from-pem /tmp/original.pem icvc-mainnet
   icp identity default icvc-mainnet
   shred -u /tmp/original.pem   # don't leave a key file on disk
   ```

2. **icp-cli mappings file.** icp-cli reads connected-network (ic) canister ids from `.icp/data/mappings/ic.ids.json` (persistent — **committed** in this repo; *not* the ephemeral `.icp/cache/mappings/`, which is only for the local managed network). It is already present, and `scripts/deploy.sh -e ic` auto-seeds it from the committed `canister_ids.json` if missing — so normally there's nothing to do. To (re)seed manually:

   ```bash
   mkdir -p .icp/data/mappings
   python3 - <<'PY'
   import json
   src = json.load(open('canister_ids.json'))
   out = {k: v['ic'] for k, v in src.items() if 'ic' in v}
   json.dump(out, open('.icp/data/mappings/ic.ids.json', 'w'), indent=2)
   PY
   ```

3. **Tests pass locally.** `mops test` and `bash tests/integration.sh` both green on `-e local`. The integration suite can't be run against mainnet (it would wipe state via approve/redeem), but it proves the build is internally consistent.

---

## 2. Routine mainnet upgrade (no stable-schema change)

When the change is code-only — new methods, new logic in existing methods, comment/docs touch-ups — the upgrade is straightforward:

```bash
bash scripts/deploy.sh -e ic
```

Under the hood this does:
- `icp build` (compiles the new WASM)
- Skip ledger installs
- `icp canister install redemption -e ic --mode upgrade` (preserves state)
- `icp deploy frontend -e ic --mode upgrade` (asset canister upgrade re-syncs files)

Sanity checks the script runs at the end:
- `icrc1_balance_of` on the redemption canister against both ledgers (verifies the 20M ICVC + ~781k ICP balances are intact).

Verify post-deploy by hand:

```bash
icp canister call -e ic redemption getStats '()'
icp canister call -e ic redemption listAdmins '()' --query
icp canister call -e ic redemption getExchangeRate '()' --query
```

---

## 3. Stable-schema change WITH data preserved (the real value path)

Motoko refuses any upgrade that silently drops persisted data (`M0263`, `M0216` errors). When you genuinely need to evolve the stable schema and keep the existing rows, the canonical pattern is **a paired PR**:

### PR A — add the migration

Add `src/redemption/Migration.mo` describing the old → new shape, and reference it from `main.mo`:

```motoko
// main.mo
import Migration "Migration";

(with migration = Migration.migrate)
persistent actor class RedemptionCanister(init : Types.InitArgs) = self {
    // ... new schema ...
};
```

`Migration.migrate` declares the *old* shape of each affected stable variable as its input and the *new* shape as its output. Variables not named in the migration carry through unchanged.

Two examples this repo has actually shipped (now landed and removed):

- **Saga consolidation** (folded a parallel `dedupKeys` map into `InFlightRedemption`): see git log for PR #10 (`saga-consolidate-add-migration`).
- **Saga cleanup** removal of the migration after mainnet upgraded: see PR #11 (`saga-consolidate-remove-migration`).

> **One-shot rule:** the migration function only fires on the upgrade where it lands. After it runs on mainnet, the input fields don't exist on-disk anymore, so subsequent deploys would fail with `M0263`. That's why every migration needs a paired removal PR.

### Apply it

1. Land PR A on `main`.
2. Run `bash scripts/deploy.sh -e ic`. The migration function fires once during the upgrade. State is folded.
3. Verify with public queries that data is intact.
4. **Land PR B immediately** (remove `Migration.mo` and the `(with migration = ...)` annotation). Until PR B lands, every subsequent `-e ic` deploy fails with the M0263/M0216 errors. Local deploys also fail unless they use `--mode reinstall` to sidestep the check.

### Why the two-PR dance

You can't keep the migration around "just in case" — once mainnet is at the new shape, the migration's input fields are gone, and Motoko refuses any further upgrades. So:

| Step | Repo state | Mainnet state |
|---|---|---|
| Before | old schema, no migration | old schema |
| Merge PR A | new schema + migration | old schema |
| Run deploy | new schema + migration | **new schema** (migration fired) |
| Merge PR B | new schema, no migration | new schema |
| Future deploys | clean `--mode upgrade` | new schema |

If you don't run the deploy between PR A and PR B, mainnet will be permanently stuck on the old schema. If you do PR B without PR A first, mainnet upgrade fails Motoko's compatibility check.

---

## 4. Stable-schema change WITHOUT data preserved (play-token shortcut)

If the canister's state is replaceable (admins are easy to re-add, redemption history is just demo data, the saga journal is empty in steady state), you don't need a migration function. Wipe the canister and start fresh:

```bash
bash scripts/deploy.sh -e ic --reinstall-redemption
```

This:
- `icp canister install redemption -e ic --mode reinstall --yes ...` (wipes the canister's state and installs the new code).
- Does NOT touch the ledgers. The 20M ICVC + 781,458 ICP balances on the ledger canisters survive unchanged (they're tracked there, not in redemption).

Things that get reset:
- `admins` → just the deployer principal
- `redemptions` → empty
- `inFlight` saga journal → empty
- All counters (`nextRedemptionId`, `totalIcvcRedeemed`, `totalIcpDistributed`) → 0

Things that survive (because they live on the ledger):
- The redemption canister's ICVC and ICP balances
- All user balances of either token
- All ledger transaction history

After reinstall, re-do the post-deploy admin steps (see §5).

---

## 5. Post-deploy checklist

Whatever path you took:

1. **Verify state with public queries** (no auth needed):
   ```bash
   icp canister call -e ic redemption getStats '()'
   icp canister call -e ic redemption listAdmins '()' --query
   icp canister call -e ic redemption getExchangeRate '()' --query
   ```

2. **Add a backup admin** (no-single-key principle):
   ```bash
   echo y | icp canister call -e ic redemption addAdmin '(principal "<BACKUP_PRINCIPAL>")'
   icp canister call -e ic redemption listAdmins '()' --query   # confirm 2 admins
   ```

3. **Add a backup controller** at the canister level (separate from the admin allowlist):
   ```bash
   icp canister settings update redemption -e ic --add-controller <BACKUP_PRINCIPAL>
   ```

4. **Verify cycles headroom** (target ≥ 90 days):
   ```bash
   icp canister status redemption -e ic
   ```
   Top up if needed:
   ```bash
   icp canister top-up redemption --cycles 5T -e ic
   ```

---

## 6. Rollback

There is no general rollback. Motoko upgrades are one-way: state is migrated forward, and the previous WASM is gone after install.

If a deploy fails:
- A failed `--mode upgrade` leaves the previous WASM intact (the upgrade is atomic per the IC protocol). Re-deploy the previous commit's WASM if needed.
- A failed `--mode reinstall` leaves the canister empty (the old WASM was uninstalled before the new one failed to install). Re-deploy any working WASM to restore service.

The safety net is **frequent small upgrades** rather than batched ones. Every PR that touches the canister code should land on mainnet within a few days of the merge; that way each upgrade's diff is small and any regression is easy to identify.

---

## 7. Real-value production cutover (`-e prod`)

The play deployment lives under the `ic` environment (our own ICRC-1 ledger copies, canisters `yofbu`/`zdlf2`). The real-value deployment is a **separate `prod` environment** (same `ic` network) so its ids never collide with play: they live in `.icp/data/mappings/prod.ids.json`, and the real ledger ids are committed in `canister_ids.json` under the `prod` key (ICVC `m6xut-mqaaa-aaaaq-aadua-cai`, ICP `ryjl3-tyaaa-aaaaa-aaaba-cai`). `deploy.sh` resolves those into the redemption init args and the frontend `config.js` — there are no hardcoded ledger principals.

Run this from a **fresh clone** (so the play mappings/cache can't interfere), as the **HSM identity** (PIN-protected — each `create`/`install` will prompt to sign):

```bash
# 0. Identity must be the HSM and a funded controller-capable principal.
icp identity default <hsm-identity>      # principal bcsqz-d32y3-...-eqe

# 1. First deploy: creates the prod redemption + frontend canisters, builds the
#    redemption wasm reproducibly (Docker) + hash-gates it, installs with the
#    REAL ledger ids resolved from the prod registry, and syncs the frontend.
#    Keep login OFF until II is aligned with the NNS dApp (see CONTRIBUTING.md).
LOGIN_ENABLED=false bash scripts/deploy.sh -e prod
```

Default modes for a first `-e prod` deploy are `REDEMPTION_MODE=install` + `FRONTEND_MODE=reinstall` (empty, freshly-created canisters). For **later** upgrades, preserve state:

```bash
REDEMPTION_MODE=upgrade FRONTEND_MODE=upgrade bash scripts/deploy.sh -e prod
```

### Post-deploy (still as the HSM)

1. **Verify the ledger wiring** (the wasm hash proves the code; this proves the wiring):
   ```bash
   PROD=$(python3 -c "import json;print(json.load(open('.icp/data/mappings/prod.ids.json'))['redemption'])")
   icp canister call -n ic "$PROD" getLedgers '()' --query
   # must show icvc_ledger = m6xut-… and icp_ledger = ryjl3-…
   icp canister call -n ic "$PROD" getStats '()'
   ```

2. **Set the controllers** to `{HSM, colleague, SNS root}` and drop any extra. `icp canister create` left the HSM as sole controller; add the other two, then confirm:
   ```bash
   icp canister settings update "$PROD" -n ic \
     --add-controller j3v5w-jzsmr-oliz7-sstl4-vzdzm-ez75n-oz46a-r6rji-zevtn-ler3c-wqe \
     --add-controller nuywj-oaaaa-aaaaq-aadta-cai
   icp canister info "$PROD" -n ic        # confirm exactly the 3 intended controllers
   ```
   Do the same for the frontend canister id.

3. **Fund the ICP pool** — the DAO transfers the payout ICP to `$PROD` on the real ICP ledger (`ryjl3-…`). Pool accounting then tracks the live `icrc1_balance_of` (see "Phased funding model" in `README.md`). Do this **only after** the security review and the controller/wiring checks above pass.

> The `prod` env never deploys the ledgers (`DO_LEDGERS=0`) and never touches the play `ic` canisters. The only shared infrastructure is the `ic` network itself.

---

## Quick reference: which mode for which situation?

| Situation | `-e local` | `-e ic` | Notes |
|---|---|---|---|
| First-time deploy | reinstall everything | (script doesn't create mainnet canisters — those exist already) | |
| Code-only change | reinstall everything | `--mode upgrade` for redemption | Default `bash scripts/deploy.sh -e ic` |
| Schema change, data important | reinstall everything | `--mode upgrade` after merging a Migration.mo PR | §3 above |
| Schema change, data replaceable | reinstall everything | `--reinstall-redemption` | §4 above |
| Just want to flush mainnet state | n/a (local is always fresh) | `--reinstall-redemption` | Wipes redemption canister but not the ledgers |
