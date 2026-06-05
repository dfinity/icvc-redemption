# Contributing

How to set up a local development environment and contribute changes.

## Prerequisites

- macOS or Linux. (Windows untested.)
- [`icp-cli`](https://github.com/dfinity/icp-cli) ≥ 0.2.7. On macOS: `brew install icp-cli`. The legacy `dfx` is no longer required for routine workflows; the deploy script does keep one `dfx` fallback for the mainnet frontend-asset upload step, so you'll need `dfx` installed if you plan to deploy to `-e ic` from your machine.
- Node.js (only needed to install `mops` via `npm`).
- `mops` for the Motoko package manager: `npm install -g ic-mops`.
- Python 3 for the small helper scripts.

## One-time setup

```bash
# Create a dev identity (non-anonymous default required for create/install)
icp identity new icvc-dev --storage plaintext --quiet
icp identity default icvc-dev

# Mops will fetch its moc 1.8.2 on first run
mops install
```

A fresh `icvc-dev` identity has zero ICP, so the first local deploy fails with "Insufficient cycles". The local network seeds the anonymous principal; transfer some ICP across and mint cycles once:

```bash
echo y | icp token transfer 100 "$(icp identity principal)" -e local --identity anonymous
echo y | icp cycles mint --cycles 50t -e local
```

## Deploy locally

```bash
# Starts the local network if not running, builds + creates + installs all
# canisters, generates frontend config.js, syncs assets.
bash scripts/deploy.sh -e local

# Open the frontend
FRONTEND=$(python3 -c "import json; print(json.load(open('.icp/cache/mappings/local.ids.json'))['frontend'])")
open "http://$FRONTEND.localhost:8000"
```

## Run tests

Two layers; both should pass before opening a PR.

```bash
mops test                                          # Motoko unit tests
bash tests/integration.sh                          # icp-cli local network integration
bash tests/integration.sh --case redeem            # filter by substring
```

`mops test` runs in CI on every PR (see [`.github/workflows/test.yml`](./.github/workflows/test.yml)). The integration suite is not yet wired into CI — run it locally before merging anything that touches the redemption flow.

A third layer (PocketIC-based, in `tests/pocketic/`) covers deterministic-time and failure-path scenarios that the bash suite cannot (faucet cooldown, pool drain, ICP-send failure → refund recovery, and more). See [`tests/pocketic/README.md`](./tests/pocketic/README.md) for setup and the current scenario list.

See [`CLAUDE.md`](./CLAUDE.md) for the coverage map (which cases protect which behaviours) and the "how to add a new case" recipe.

## Common one-shots

```bash
# Type-check Motoko without deploying (uses the moc the test runner pins)
$(mops toolchain bin moc) $(mops sources) --check src/redemption/main.mo

# Get a faucet hit (10s cooldown per principal)
echo y | icp canister call -e local redemption faucet '()'

# Approve + redeem
REDEMPTION_ID=$(python3 -c "import json; print(json.load(open('.icp/cache/mappings/local.ids.json'))['redemption'])")
echo y | icp canister call -e local icvc_ledger icrc2_approve "(record {
    from_subaccount = null;
    spender = record { owner = principal \"$REDEMPTION_ID\"; subaccount = null };
    amount = 100_000_000 : nat;
    expected_allowance = null; expires_at = null;
    fee = null; memo = null; created_at_time = null
})"
echo y | icp canister call -e local redemption redeem '(100_000_000 : nat)'

# Queries (--query) skip the confirmation prompt
icp canister call -e local redemption getStats '()' --query
icp canister call -e local redemption getInFlight '()' --query
icp canister call -e local redemption listAdmins '()' --query
```

`icp canister call` prompts for confirmation on update calls; pipe `y` via stdin to skip it. Queries (`--query`) don't prompt.

## Rebuilding the redemption canister after Motoko changes

`--mode upgrade` preserves stable state (admins, redemption history, saga journal):

```bash
icp canister install redemption -e local --mode upgrade --yes --args '(record {
    icvc_ledger_id = principal "<ICVC_ID>";
    icp_ledger_id  = principal "<ICP_ID>";
    admin = principal "<DEPLOYER>";
})'
```

Stable-schema changes (e.g., adding/removing a stable variable) need either a `Migration.mo` paired-PR pattern or `--mode reinstall`. See [`MIGRATIONS.md`](./MIGRATIONS.md).

## Frontend bundle

`@dfinity/*` JS packages are pre-bundled into `src/frontend/js/dfinity.js` (gitignored). `scripts/deploy.sh` runs the bundle automatically before syncing assets (it requires `npm` on PATH; Node ≥ 20). If you're editing `js/dfinity-bundle.js` between deploys and want to rebuild manually:

```bash
cd src/frontend && npm run build
```

There is no watch mode today; rebuild manually with the command above after editing the bundle entry.

## Mainnet II principal derivation (gated, off by default)

On mainnet the SPA can ask Internet Identity to derive principals from `nns.ic0.app`, so a holder signs in with the same principal that holds their ICVC in the NNS dApp. This is **disabled by default** because it only works once `nns.ic0.app` lists this dapp's origin in its `/.well-known/ii-alternative-origins`; enabling it before then makes II reject every login ("origin not trusted").

Leave it off for the play deployment (login works; holders just get a fresh per-origin principal). Once the `ii-alternative-origins` listing is live, enable it for that one deploy:

```bash
ENABLE_NNS_DERIVATION=1 bash scripts/deploy.sh -e ic
```

## Opening a pull request

1. Branch off `main`. Naming convention: short kebab-case (`fix-icp-call-for-ic`, `add-status-badge`).
2. Run both test layers locally; both must pass.
3. Push the branch; open the PR. CI will run `mops test` on the PR.
4. Address review (CODEOWNERS auto-requested).
5. Squash-merge after approval + CI green.

For mainnet-touching changes, also follow [`MIGRATIONS.md`](./MIGRATIONS.md) to decide between upgrade and reinstall, and update [`TODO.md`](./TODO.md) if the change resolves an open item.
