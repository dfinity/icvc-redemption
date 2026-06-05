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
#   - .icp/cache/mappings/ic.ids.json must list the existing mainnet canister
#     ids. Seed it from canister_ids.json:
#
#       mkdir -p .icp/cache/mappings
#       python3 - <<'PY'
#       import json
#       src = json.load(open('canister_ids.json'))
#       out = {k: v['ic'] for k, v in src.items() if 'ic' in v}
#       json.dump(out, open('.icp/cache/mappings/ic.ids.json', 'w'), indent=2)
#       PY
#
#   - `dfx` is required as a fallback for the frontend asset upload on -e ic.
#     icp-cli 0.2.7 cannot sync assets to an existing asset canister on a
#     connected network; the script writes a minimal dfx.json and runs
#     `dfx deploy frontend --network ic` for that step only. Override the
#     dfx identity name via DFX_IDENTITY=<name>; defaults to `icvc`.
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
  FRONTEND_MODE=upgrade   # asset canister upgrade = resync
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

# Read a canister id assigned (or recorded) by icp-cli for the current env.
canister_id() {
  local name="$1"
  python3 -c "
import json
with open('.icp/cache/mappings/${ENV}.ids.json') as f:
    print(json.load(f)['${name}'])
"
}

# Invoke a canister call non-interactively. `icp canister call` has no --yes
# flag and prompts for confirmation on update calls; we pipe `y`.
#
# For -e ic, icp-cli 0.2.7 cannot resolve canister names against
# .icp/cache/mappings/ic.ids.json for connected networks (the lookup is
# local-only). Translate the name to a principal and use -n ic in that case.
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
  if [[ ! -f .icp/cache/mappings/ic.ids.json ]]; then
    cat <<'EOF' >&2
Error: .icp/cache/mappings/ic.ids.json is missing.

This script never creates mainnet canisters — it only installs into
existing ones. Seed the mappings file from canister_ids.json first:

  mkdir -p .icp/cache/mappings
  python3 - <<'PY'
  import json
  src = json.load(open('canister_ids.json'))
  out = {k: v['ic'] for k, v in src.items() if 'ic' in v}
  json.dump(out, open('.icp/cache/mappings/ic.ids.json', 'w'), indent=2)
  PY
EOF
    exit 1
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

# ---- Step 2: build all canister WASMs --------------------------------------

echo ""
echo "--- Building canisters ---"
icp build

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

echo ""
echo "--- Installing Redemption canister (mode: $REDEMPTION_MODE) ---"
if [[ "$ENV" == "ic" ]]; then
  # icp-cli 0.2.7 quirk: `icp canister install <name> -e ic` cannot resolve
  # canister names against .icp/cache/mappings/ic.ids.json for connected
  # networks (the lookup is local-only). Work around by targeting the
  # principal directly with -n ic and passing --wasm explicitly.
  icp canister install "$REDEMPTION_ID" -n ic --mode "$REDEMPTION_MODE" --yes \
      --wasm .icp/cache/artifacts/redemption \
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

# ---- Step 9a: build the @dfinity/* esbuild bundle -------------------------
#
# js/dfinity.js is gitignored (it's a build artifact) and js/app.js imports
# it as a module. A fresh checkout would otherwise deploy a frontend missing
# the bundle. Build it here unconditionally; npm + esbuild are cheap.

echo ""
echo "--- Building frontend @dfinity/* bundle (esbuild) ---"
if ! command -v npm >/dev/null 2>&1; then
  echo "ERROR: npm is required to build the frontend bundle (esbuild). Install Node.js >= 20." >&2
  exit 1
fi
(cd src/frontend && \
  if [[ ! -d node_modules ]]; then npm ci --silent --no-audit --no-fund >/dev/null; fi && \
  npm run --silent build)
if [[ ! -s src/frontend/js/dfinity.js ]]; then
  echo "ERROR: src/frontend/js/dfinity.js missing or empty after build." >&2
  exit 1
fi

# ---- Step 9b: generate frontend runtime config ----------------------------

echo ""
echo "--- Generating src/frontend/js/config.js from template ---"
sed \
  -e "s|__CANISTER_ID_REDEMPTION__|$REDEMPTION_ID|g" \
  -e "s|__CANISTER_ID_ICVC_LEDGER__|$ICVC_LEDGER_ID|g" \
  -e "s|__CANISTER_ID_ICP_LEDGER__|$ICP_LEDGER_ID|g" \
  -e "s|__HOST__|$HOST|g" \
  -e "s|__II_PROVIDER__|$II_PROVIDER|g" \
  -e "s|__DERIVATION_ORIGIN__|$DERIVATION_ORIGIN|g" \
  src/frontend/js/config.js.template > src/frontend/js/config.js

echo "--- Installing frontend (mode: $FRONTEND_MODE, then sync assets) ---"
if [[ "$ENV" == "ic" ]]; then
  # icp-cli 0.2.7 quirk: `icp deploy frontend -e ic` cannot sync assets to
  # an existing asset canister on a connected network. Fall back to dfx
  # for the asset upload only. We write a *minimal* dfx.json with just the
  # frontend canister so dfx doesn't also try to redeploy the ledgers or
  # the redemption canister (which would need install args dfx can't see).
  # The asset canister IDs come from the committed `canister_ids.json`.
  if ! command -v dfx >/dev/null 2>&1; then
    echo "ERROR: dfx is required to upload frontend assets to an existing" >&2
    echo "       mainnet asset canister. icp-cli 0.2.7 does not support this" >&2
    echo "       path; we use dfx as a thin fallback until upstream catches up." >&2
    echo "       Install dfx via:" >&2
    echo "         sh -ci \"\$(curl -fsSL https://internetcomputer.org/install.sh)\"" >&2
    exit 1
  fi
  cat > dfx.json <<'EOF'
{
  "canisters": {
    "frontend": {
      "type": "assets",
      "source": ["src/frontend"]
    }
  },
  "networks": { "ic": { "type": "persistent" } }
}
EOF
  trap 'rm -f dfx.json' EXIT
  DFX_IDENTITY="${DFX_IDENTITY:-icvc}"
  dfx --identity "$DFX_IDENTITY" deploy frontend --network ic --mode upgrade >/dev/null
  rm -f dfx.json
  trap - EXIT
else
  icp deploy frontend -e "$ENV" --yes -m "$FRONTEND_MODE" >/dev/null
fi

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
