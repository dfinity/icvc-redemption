#!/bin/bash
set -euo pipefail

# ICVC Redemption Canister - Deployment Script (icp-cli).
#
# Two environments, two very different policies:
#
#   -e local  Dev box. Every canister reinstalled fresh, Internet Identity
#             included. No state is precious. Fresh deploys start with an
#             empty redemption history; use `faucet` + `redeem` to populate
#             it during testing.
#
#   -e ic     Mainnet. **State on the ledger canisters is precious** (the
#             pre-minted 20M ICVC and 781,458 ICP balances live there). This
#             script NEVER touches the mainnet ledgers; it only upgrades the
#             redemption canister (--mode upgrade by default, preserving its
#             admins / redemption history / saga journal) and re-syncs the
#             frontend assets.
#
#             Pass --reinstall-redemption for the ONE-TIME schema-flip after
#             a Motoko-incompatible refactor. That wipes the redemption
#             canister's state (admins, redemption history, faucet claims).
#             The ledger balances still survive because they're tracked on
#             the ledger canisters, not inside the redemption canister.
#
# Usage:
#   bash scripts/deploy.sh                            # default: -e local
#   bash scripts/deploy.sh -e local
#   bash scripts/deploy.sh -e ic                      # safe upgrade
#   bash scripts/deploy.sh -e ic --reinstall-redemption  # one-time schema flip
#
# Prerequisites for -e ic:
#   - Your icp-cli identity must be a controller of the mainnet canisters
#     (import the original deploy PEM via: icp identity import --from-pem ...).
#   - .icp/data/mappings/ic.ids.json maps the canister names to the existing
#     mainnet ids so icp-cli REUSES them (rather than creating new canisters).
#     This file is committed; Step 0 also auto-seeds it from canister_ids.json
#     if missing. (Note: connected-network ids live in .icp/data/ — persistent;
#     .icp/cache/ is ephemeral and only used for the local managed network.)
#
#   - Docker is required on -e ic: the redemption WASM is built reproducibly
#     via Dockerfile.build (linux/amd64) and hash-gated against
#     redemption.wasm.sha256 before install, so the on-chain module_hash
#     matches what auditors can rebuild (see REPRODUCIBLE_BUILD.md).
#   - The frontend is the @dfinity/asset-canister recipe (icp-cli 1.0.0): its
#     bundled plugin syncs assets to the existing mainnet asset canister, so no
#     dfx fallback is needed anymore.
#
# See MIGRATIONS.md for the playbook on stable-schema changes.

cd "$(dirname "$0")/.."

# ---- Parse arguments -------------------------------------------------------

ENV="local"
REINSTALL_REDEMPTION=0
# Gate for NNS principal derivation on mainnet (see the -e ic branch below).
# Off by default; safe-default under `set -u`. Override: ENABLE_NNS_DERIVATION=1
ENABLE_NNS_DERIVATION="${ENABLE_NNS_DERIVATION:-0}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--environment) ENV="$2"; shift 2 ;;
    --network)
      # Accept the legacy --network flag so old muscle memory still works.
      ENV="$2"; shift 2 ;;
    --reinstall-redemption) REINSTALL_REDEMPTION=1; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ "$ENV" != "local" && "$ENV" != "ic" ]]; then
  echo "Error: -e must be 'local' or 'ic'"
  exit 1
fi
if [[ "$REINSTALL_REDEMPTION" == "1" && "$ENV" != "ic" ]]; then
  echo "Error: --reinstall-redemption only makes sense with -e ic"
  echo "       (local always reinstalls everything)"
  exit 1
fi

# ---- Per-environment policy -----------------------------------------------

if [[ "$ENV" == "local" ]]; then
  HOST="http://127.0.0.1:8000"
  II_PROVIDER=""   # filled in once the local II canister is created
  DERIVATION_ORIGIN=""    # local: keep principals scoped to the local frontend origin
  DO_II=1
  DO_LEDGERS=1            # reinstall ledgers; seed balances
  REDEMPTION_MODE=reinstall
  FRONTEND_MODE=reinstall
else
  HOST="https://icp0.io"
  II_PROVIDER="https://identity.ic0.app"
  # Mainnet: optionally derive principals from nns.ic0.app so holders sign in
  # with the same principal that holds their ICVC in the NNS dApp. This ONLY
  # works once nns.ic0.app lists this dapp's origin in its
  # /.well-known/ii-alternative-origins; until then, turning it on makes II
  # reject every login ("origin not trusted"). So it is gated OFF by default
  # and the play deployment keeps per-origin principals (login works, holders
  # just get a fresh principal). Flip it on only after that listing is live:
  #   ENABLE_NNS_DERIVATION=1 bash scripts/deploy.sh -e ic
  if [[ "$ENABLE_NNS_DERIVATION" == "1" || "$ENABLE_NNS_DERIVATION" == "true" ]]; then
    DERIVATION_ORIGIN="https://nns.ic0.app"
    echo "NNS principal derivation: ENABLED (nns.ic0.app must list this dapp in ii-alternative-origins)"
  else
    DERIVATION_ORIGIN=""
    echo "NNS principal derivation: disabled (set ENABLE_NNS_DERIVATION=1 to enable once ii-alternative-origins is live)"
  fi
  DO_II=0                 # mainnet uses the global identity.ic0.app
  DO_LEDGERS=0            # NEVER touch mainnet ledger state
  REDEMPTION_MODE=upgrade # preserves state
  # Asset-canister upgrade = re-sync. Overridable: the FIRST deploy that
  # switches the frontend from the old SDK assetstorage wasm to the
  # @dfinity/asset-canister recipe wasm should use reinstall, because an
  # in-place upgrade across the two wasm lineages may trap in post_upgrade.
  # Reinstall is safe here (assets are re-uploaded by the sync step; canister
  # id, controllers, and cycles are preserved). After the switch, upgrade is
  # fine.  Run the one-time switch with: FRONTEND_MODE=reinstall ... -e ic
  FRONTEND_MODE="${FRONTEND_MODE:-upgrade}"
  if [[ "$REINSTALL_REDEMPTION" == "1" ]]; then
    REDEMPTION_MODE=reinstall
  fi
fi

echo "=== ICVC Redemption Canister — Deploy (env: $ENV) ==="
DEPLOYER=$(icp identity principal)
echo "Deployer principal: $DEPLOYER"
echo "Redemption mode:    $REDEMPTION_MODE"
[[ "$DO_LEDGERS" -eq 1 ]] && echo "Ledgers:            reinstall" || echo "Ledgers:            SKIPPED (mainnet state is precious)"
if [[ "$ENV" == "ic" && "$REINSTALL_REDEMPTION" == "1" ]]; then
  echo ""
  echo "*** WARNING: --reinstall-redemption WILL WIPE the mainnet redemption canister state ***"
  echo "***   - admins reset to deployer principal only                                     ***"
  echo "***   - redemption history wiped (empty until real activity)                        ***"
  echo "***   - saga journal wiped                                                          ***"
  echo "***   - faucetClaims wiped                                                          ***"
  echo "*** Ledger balances are NOT touched.                                                ***"
fi

# ---- Helpers ---------------------------------------------------------------

# Read a canister id recorded by icp-cli for the current env. icp-cli stores
# connected-network (ic) ids in the PERSISTENT .icp/data/mappings/, and managed
# (local) ids in the ephemeral .icp/cache/mappings/ it rebuilds itself.
canister_id() {
  local name="$1"
  local dir="cache"
  [[ "$ENV" == "ic" ]] && dir="data"
  python3 -c "
import json
with open('.icp/${dir}/mappings/${ENV}.ids.json') as f:
    print(json.load(f)['${name}'])
"
}

# Invoke a canister call non-interactively. `icp canister call` has no --yes
# flag and prompts for confirmation on update calls; we pipe `y`.
#
# For -e ic we translate the canister name to a principal and use -n ic.
# Targeting the principal directly is version-independent and avoids depending
# on icp-cli's connected-network name resolution (which reads
# .icp/data/mappings/ic.ids.json — now seeded in Step 0).
icp_call() {
  local name="$1"
  shift
  if [[ "$ENV" == "ic" ]]; then
    local principal
    principal=$(canister_id "$name")
    echo "y" | icp canister call -n ic "$principal" "$@"
  else
    echo "y" | icp canister call -e "$ENV" "$name" "$@"
  fi
}

# ---- Step 0: pre-flight for mainnet ---------------------------------------

if [[ "$ENV" == "ic" ]]; then
  # icp-cli reads connected-network ids from .icp/data/mappings/ic.ids.json
  # (persistent; committed in this repo). Without it, `icp deploy`/install would
  # try to CREATE new mainnet canisters instead of reusing the existing ones.
  # It is committed, but seed it from canister_ids.json as a fallback if absent
  # (icp-cli has no canister_ids.json fallback of its own).
  if [[ ! -f .icp/data/mappings/ic.ids.json ]]; then
    echo "Seeding .icp/data/mappings/ic.ids.json from canister_ids.json..."
    mkdir -p .icp/data/mappings
    python3 - <<'PY'
import json
src = json.load(open('canister_ids.json'))
out = {k: v['ic'] for k, v in src.items() if 'ic' in v}
json.dump(out, open('.icp/data/mappings/ic.ids.json', 'w'), indent=2)
PY
  fi
fi

# ---- Step 1: ensure the local network is running ---------------------------

if [[ "$ENV" == "local" ]]; then
  if ! icp network ping local >/dev/null 2>&1; then
    echo ""
    echo "--- Starting local network ---"
    icp network start local --background >/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      icp network ping local >/dev/null 2>&1 && break
      sleep 1
    done
  fi
fi

# ---- Step 2: build canister WASMs (NOT the frontend) -----------------------
#
# The frontend is the @dfinity/asset-canister recipe; its build (npm + esbuild
# + dist assembly) requires js/config.js, which isn't generated until Step 9.
# So the frontend is built later, during `icp deploy frontend`. Here we build
# only the canisters that are installed by name from the build output:
#   - local: Internet Identity + both ledgers + redemption
#   - ic:    none — redemption installs the reproducible Docker wasm (Step 7),
#            the ledgers are untouched, and the frontend builds during deploy.
echo ""
if [[ "$ENV" == "local" ]]; then
  echo "--- Building canisters (local: all except frontend) ---"
  icp build internet_identity icvc_ledger icp_ledger redemption
else
  echo "--- Skipping icp build (ic: redemption via Docker; frontend via deploy) ---"
fi

# ---- Step 3: create empty canisters (local only; mainnet canisters exist) -

create_if_missing() {
  local name="$1"
  if icp canister status "$name" -e "$ENV" >/dev/null 2>&1; then
    return 0
  fi
  echo "Creating ${name}..."
  icp canister create "$name" -e "$ENV" >/dev/null
}

if [[ "$ENV" == "local" ]]; then
  CANISTERS=(internet_identity icvc_ledger icp_ledger redemption frontend)
  echo ""
  echo "--- Creating canisters (skip if already present) ---"
  for c in "${CANISTERS[@]}"; do create_if_missing "$c"; done
fi

# ---- Step 4: collect canister ids ------------------------------------------

ICVC_LEDGER_ID=$(canister_id icvc_ledger)
ICP_LEDGER_ID=$(canister_id icp_ledger)
REDEMPTION_ID=$(canister_id redemption)
FRONTEND_ID=$(canister_id frontend)
if [[ "$ENV" == "local" ]]; then
  II_ID=$(canister_id internet_identity)
  II_PROVIDER="http://${II_ID}.localhost:8000"
fi

echo ""
echo "Canister IDs:"
[[ "$ENV" == "local" ]] && echo "  Internet Identity: $II_ID"
echo "  ICVC Ledger:       $ICVC_LEDGER_ID"
echo "  ICP Ledger:        $ICP_LEDGER_ID"
echo "  Redemption:        $REDEMPTION_ID"
echo "  Frontend:          $FRONTEND_ID"

# ---- Step 5: install Internet Identity (local only) ------------------------

if [[ "$DO_II" -eq 1 ]]; then
  echo ""
  echo "--- Installing Internet Identity ---"
  icp canister install internet_identity -e "$ENV" --mode reinstall --yes --args '(null)' >/dev/null
fi

# ---- Step 6: install ledgers (local only) ---------------------------------

if [[ "$DO_LEDGERS" -eq 1 ]]; then
  echo ""
  echo "--- Installing ICVC ledger ---"
  icp canister install icvc_ledger -e "$ENV" --mode reinstall --yes --args "(variant { Init = record {
      minting_account = record {
          owner = principal \"$DEPLOYER\";
          subaccount = opt blob \"\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\01\";
      };
      fee_collector_account = null;
      transfer_fee = 10_000 : nat;
      decimals = opt (8 : nat8);
      max_memo_length = opt (256 : nat16);
      token_symbol = \"ICVC\";
      token_name = \"ICVC Token\";
      metadata = vec {};
      initial_balances = vec {
          record { record { owner = principal \"$REDEMPTION_ID\"; subaccount = null }; 2_000_000_000_000_000 : nat };
      };
      feature_flags = opt record { icrc2 = true };
      maximum_number_of_accounts = null;
      accounts_overflow_trim_quantity = null;
      archive_options = record {
          num_blocks_to_archive = 1000 : nat64;
          max_transactions_per_response = null;
          trigger_threshold = 2000 : nat64;
          max_message_size_bytes = null;
          cycles_for_archive_creation = opt (10_000_000_000_000 : nat64);
          node_max_memory_size_bytes = null;
          controller_id = principal \"$DEPLOYER\";
          more_controller_ids = null;
      };
  }})" >/dev/null

  echo ""
  echo "--- Installing ICP ledger ---"
  icp canister install icp_ledger -e "$ENV" --mode reinstall --yes --args "(variant { Init = record {
      minting_account = record {
          owner = principal \"$DEPLOYER\";
          subaccount = opt blob \"\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\00\\02\";
      };
      fee_collector_account = null;
      transfer_fee = 10_000 : nat;
      decimals = opt (8 : nat8);
      max_memo_length = opt (256 : nat16);
      token_symbol = \"ICP\";
      token_name = \"Internet Computer (Play)\";
      metadata = vec {};
      initial_balances = vec {
          record { record { owner = principal \"$REDEMPTION_ID\"; subaccount = null }; 78_145_800_000_000 : nat };
      };
      feature_flags = opt record { icrc2 = true };
      maximum_number_of_accounts = null;
      accounts_overflow_trim_quantity = null;
      archive_options = record {
          num_blocks_to_archive = 1000 : nat64;
          max_transactions_per_response = null;
          trigger_threshold = 2000 : nat64;
          max_message_size_bytes = null;
          cycles_for_archive_creation = opt (10_000_000_000_000 : nat64);
          node_max_memory_size_bytes = null;
          controller_id = principal \"$DEPLOYER\";
          more_controller_ids = null;
      };
  }})" >/dev/null
else
  echo ""
  echo "--- Skipping ledger installs (mainnet state preserved) ---"
fi

# ---- Step 7: install / upgrade Redemption ----------------------------------

# The redemption rate is no longer an init arg: it is DERIVED inside the
# canister from the fair-value backing constants (treasury ICP + nICP / total
# ICVC supply) and changes only via code upgrade. See `fairValueRate()` in
# src/redemption/main.mo and getFairValueInputs() for the live breakdown.
REDEMPTION_INIT_ARGS="(record {
    icvc_ledger_id = principal \"$ICVC_LEDGER_ID\";
    icp_ledger_id = principal \"$ICP_LEDGER_ID\";
    admin = principal \"$DEPLOYER\";
})"

# The wasm to install. Local uses whatever `icp build` produced for the host;
# mainnet MUST use the reproducible Linux x86_64 build (see REPRODUCIBLE_BUILD.md)
# so the on-chain module_hash matches what third parties can rebuild. Building
# on this host (e.g. macOS arm64) would bake a platform-specific, NON-
# reproducible hash, so for -e ic we build hermetically via Dockerfile.build
# and verify the result against the committed redemption.wasm.sha256.
REDEMPTION_WASM=".icp/cache/artifacts/redemption"
if [[ "$ENV" == "ic" ]]; then
  echo ""
  echo "--- Building reproducible redemption wasm (Docker, linux/amd64) ---"
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is required to build the reproducible mainnet wasm." >&2
    echo "       The deployed module_hash must match the Linux x86_64 build" >&2
    echo "       that CI / auditors reproduce; see REPRODUCIBLE_BUILD.md." >&2
    exit 1
  fi
  docker build --platform=linux/amd64 -f Dockerfile.build -t icvc-redemption-build . >/dev/null
  REDEMPTION_WASM="redemption.wasm"
  docker run --rm --platform=linux/amd64 -v "$PWD:/out" icvc-redemption-build \
      cp /work/redemption.wasm /out/redemption.wasm

  # Gate: refuse to deploy unless the freshly built wasm matches the committed
  # canonical hash. A mismatch means source/toolchain drifted without
  # redemption.wasm.sha256 being refreshed (run verify-wasm.sh --write on Linux).
  EXPECTED_HASH="$(awk '{print $1}' redemption.wasm.sha256)"
  if command -v sha256sum >/dev/null 2>&1; then
    BUILT_HASH="$(sha256sum redemption.wasm | awk '{print $1}')"
  else
    BUILT_HASH="$(shasum -a 256 redemption.wasm | awk '{print $1}')"
  fi
  echo "  built:    $BUILT_HASH"
  echo "  expected: $EXPECTED_HASH  (redemption.wasm.sha256)"
  if [[ "$BUILT_HASH" != "$EXPECTED_HASH" ]]; then
    echo "ERROR: reproducible-build hash mismatch — refusing to deploy to mainnet." >&2
    exit 1
  fi
  echo "  hash verified — this exact wasm becomes the on-chain module_hash."
fi

echo ""
echo "--- Installing Redemption canister (mode: $REDEMPTION_MODE) ---"
if [[ "$ENV" == "ic" ]]; then
  # Target the principal directly with -n ic and pass --wasm explicitly: this
  # is version-independent and avoids relying on icp-cli's connected-network
  # name resolution (this is also the exact path verified by the alignment
  # upgrade — see REPRODUCIBLE_BUILD.md).
  icp canister install "$REDEMPTION_ID" -n ic --mode "$REDEMPTION_MODE" --yes \
      --wasm "$REDEMPTION_WASM" \
      --args "$REDEMPTION_INIT_ARGS" >/dev/null
else
  icp canister install redemption -e "$ENV" --mode "$REDEMPTION_MODE" --yes \
      --args "$REDEMPTION_INIT_ARGS" >/dev/null
fi

# ---- Step 8: balance sanity checks ----------------------------------------

echo ""
echo "--- Verifying ICP balance of redemption canister ---"
icp_call icp_ledger icrc1_balance_of "(record { owner = principal \"$REDEMPTION_ID\"; subaccount = null })" --query
echo ""
echo "--- Verifying ICVC balance of redemption canister (faucet supply) ---"
icp_call icvc_ledger icrc1_balance_of "(record { owner = principal \"$REDEMPTION_ID\"; subaccount = null })" --query

# ---- Step 9: generate frontend config, then deploy via the asset recipe ----
#
# Under icp-cli 1.0.0 the frontend is the @dfinity/asset-canister recipe (see
# icp.yaml): `icp deploy` runs the recipe build (npm ci + esbuild bundle +
# assemble a clean dist/) and the recipe's plugin uploads the assets — on BOTH
# local and ic, including re-syncing an already-deployed canister, so the old
# dfx fallback is gone. We only need to write js/config.js first, because 1.0.0
# does not inject canister ids at build time (they are a runtime ic_env cookie);
# the recipe build copies this generated config.js into dist/.

echo ""
echo "--- Generating src/frontend/js/config.js from template ---"
if ! command -v npm >/dev/null 2>&1; then
  echo "ERROR: npm is required for the frontend recipe build (esbuild). Install Node.js >= 20." >&2
  exit 1
fi
sed \
  -e "s|__CANISTER_ID_REDEMPTION__|$REDEMPTION_ID|g" \
  -e "s|__CANISTER_ID_ICVC_LEDGER__|$ICVC_LEDGER_ID|g" \
  -e "s|__CANISTER_ID_ICP_LEDGER__|$ICP_LEDGER_ID|g" \
  -e "s|__HOST__|$HOST|g" \
  -e "s|__II_PROVIDER__|$II_PROVIDER|g" \
  -e "s|__DERIVATION_ORIGIN__|$DERIVATION_ORIGIN|g" \
  src/frontend/js/config.js.template > src/frontend/js/config.js

echo "--- Deploying frontend (asset-canister recipe builds + syncs; mode: $FRONTEND_MODE) ---"
# NOTE: on -e ic the FIRST deploy switches the frontend canister from the old
# SDK 0.30.2 assetstorage wasm to the recipe's asset-canister wasm (a module-
# hash change). Run that one-time switch with FRONTEND_MODE=reinstall (the
# cross-lineage in-place upgrade may trap; reinstall is safe — id/controllers/
# cycles preserved, assets re-uploaded by sync). Watch the output: it must say
# "All canisters already exist" (reusing the existing canister), NOT
# "Created canister frontend ..." (which would orphan the live canister).
icp deploy frontend -e "$ENV" -m "$FRONTEND_MODE" --yes >/dev/null

# ---- Done ------------------------------------------------------------------

echo ""
echo "=== Deployment Complete (env: $ENV) ==="
echo ""
echo "Canister IDs:"
echo "  ICVC Ledger:  $ICVC_LEDGER_ID"
echo "  ICP Ledger:   $ICP_LEDGER_ID"
echo "  Redemption:   $REDEMPTION_ID"
echo "  Frontend:     $FRONTEND_ID"
echo ""
# Rate is derived on-chain from the fair-value backing constants, so read it
# back rather than hardcoding (digits only, then format e8s -> decimal).
RATE_E8S=$(icp_call redemption getExchangeRate --query 2>/dev/null | tr -cd '0-9')
if [[ -n "$RATE_E8S" ]]; then
  echo "Exchange rate (fair-value derived): $(awk "BEGIN { printf \"%.8f\", $RATE_E8S / 100000000 }") ICP per ICVC"
fi
# Pool is the redemption canister's live ICP balance (read off the ledger),
# not a hardcoded figure. (digits only, then format e8s -> decimal.)
POOL_E8S=$(icp_call icp_ledger icrc1_balance_of "(record { owner = principal \"$REDEMPTION_ID\"; subaccount = null })" --query 2>/dev/null | tr -cd '0-9')
if [[ -n "$POOL_E8S" ]]; then
  echo "ICP Pool (live canister balance): $(awk "BEGIN { printf \"%.2f\", $POOL_E8S / 100000000 }") ICP"
fi
echo ""
if [[ "$ENV" == "ic" ]]; then
  echo "Frontend URL: https://$FRONTEND_ID.icp0.io"
  echo ""
  echo "Post-deploy reminders:"
  echo "  - Verify with: icp canister call -e ic redemption getStats '()'"
  echo "  - Add a backup admin (see RECOVERY.md)"
  echo "  - Add a backup controller (see RECOVERY.md)"
  echo "  - Before any real-value deployment, the faucet is removed wholesale"
  echo "    in code (method + pre-funding); see the go-live checklist in TODO.md"
else
  echo "Frontend URL: http://$FRONTEND_ID.localhost:8000"
fi
