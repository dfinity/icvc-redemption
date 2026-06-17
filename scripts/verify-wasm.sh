#!/bin/bash
set -euo pipefail

# Reproducible-build verifier for the redemption canister.
#
# Rebuilds src/redemption/main.mo with the *pinned* toolchain (moc from
# mops.toml's [toolchain], base lib from [dependencies]), computes the SHA-256
# of the resulting wasm, and compares it against:
#
#   1. the committed expected hash in `redemption.wasm.sha256` (always, if present), and
#   2. the live on-chain module hash of the mainnet redemption canister (with --onchain).
#
# PLATFORM MATTERS. mops fetches a platform-specific `moc` binary, and the
# macOS and Linux builds of the same moc version emit DIFFERENT wasm (different
# baked-in Motoko RTS), so a host build only reproduces the committed hash on
# the SAME platform it was recorded on. The committed hash and the deployed
# canister use **Linux x86_64** as the canonical reference — verify there, or
# (recommended, host-independent) via Dockerfile.build. A macOS host build will
# print a different hash and that is expected, not a tampering signal.
#
# The redemption wasm is installed UNCOMPRESSED (see scripts/deploy.sh: it
# passes `--wasm .icp/cache/artifacts/redemption`, a raw .wasm), so the IC
# `module_hash` equals the plain SHA-256 of this file — no gunzip step needed.
# (The ledger / asset / II canisters ship pre-built .wasm.gz blobs whose
# hashes are pinned in icp.yaml; this script verifies only the canister whose
# source lives in THIS repo.)
#
# Usage:
#   bash scripts/verify-wasm.sh                 # build + compare to committed hash
#   bash scripts/verify-wasm.sh --write         # build + (re)write redemption.wasm.sha256
#   bash scripts/verify-wasm.sh --onchain       # also diff against mainnet module_hash
#   bash scripts/verify-wasm.sh --onchain <id>  # ...against a specific canister id
#   bash scripts/verify-wasm.sh --out PATH      # keep the rebuilt wasm at PATH (else temp)

cd "$(dirname "$0")/.."

HASH_FILE="redemption.wasm.sha256"
REDEMPTION_IC_ID="yofbu-hiaaa-aaaae-agaeq-cai"   # mainnet; see canister_ids.json

WRITE=0
CHECK_ONCHAIN=0
ONCHAIN_ID="$REDEMPTION_IC_ID"
OUT_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --write)   WRITE=1; shift ;;
    --onchain) CHECK_ONCHAIN=1; shift
               if [[ $# -gt 0 && "$1" != --* ]]; then ONCHAIN_ID="$1"; shift; fi ;;
    --out)     OUT_PATH="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Portable SHA-256 (Linux: sha256sum; macOS: shasum -a 256).
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# ---- Build with the pinned toolchain --------------------------------------

if ! command -v mops >/dev/null 2>&1; then
  echo "ERROR: mops not found. Install with: npm install --global ic-mops" >&2
  exit 1
fi

MOC="$(mops toolchain bin moc)"
echo "platform:   $(uname -s) $(uname -m)  (canonical reference: Linux x86_64)"
echo "moc:        $("$MOC" --version)"
echo "moc binary: $MOC"

if [[ -n "$OUT_PATH" ]]; then
  OUT="$OUT_PATH"        # caller wants the artifact kept (e.g. CI upload)
else
  OUT="$(mktemp -t redemption.XXXXXX.wasm)"
  trap 'rm -f "$OUT"' EXIT
fi

# Same command icp.yaml uses for the `redemption` canister's build step.
"$MOC" src/redemption/main.mo $(mops sources) -o "$OUT"

LOCAL_HASH="$(sha256 "$OUT")"
echo ""
echo "Rebuilt redemption wasm SHA-256:"
echo "  $LOCAL_HASH"

# ---- Compare / write committed hash ---------------------------------------

if [[ "$WRITE" -eq 1 ]]; then
  echo "$LOCAL_HASH  redemption.wasm" > "$HASH_FILE"
  echo ""
  echo "Wrote $HASH_FILE"
elif [[ -f "$HASH_FILE" ]]; then
  EXPECTED="$(awk '{print $1}' "$HASH_FILE")"
  echo ""
  if [[ "$LOCAL_HASH" == "$EXPECTED" ]]; then
    echo "MATCH: rebuilt wasm == committed $HASH_FILE"
  else
    echo "MISMATCH: committed $HASH_FILE = $EXPECTED" >&2
    echo "          rebuilt          = $LOCAL_HASH" >&2
    echo "The source no longer reproduces the committed hash. Either the source" >&2
    echo "changed (run --write to update) or the toolchain drifted (check moc /" >&2
    echo "base versions in mops.toml)." >&2
    exit 1
  fi
else
  echo ""
  echo "(no $HASH_FILE committed yet — run with --write to record this hash)"
fi

# ---- Compare against the live on-chain module hash ------------------------

if [[ "$CHECK_ONCHAIN" -eq 1 ]]; then
  echo ""
  echo "--- On-chain module hash for $ONCHAIN_ID ---"
  if ! command -v dfx >/dev/null 2>&1; then
    echo "dfx not found; cannot read the on-chain module hash automatically." >&2
    echo "Read it manually (anonymous, no controller rights needed):" >&2
    echo "  dfx canister info $ONCHAIN_ID --network ic" >&2
    exit 1
  fi
  # `dfx canister info` uses an anonymous read_state call; any identity works.
  ONCHAIN_RAW="$(dfx canister info "$ONCHAIN_ID" --network ic 2>/dev/null || true)"
  echo "$ONCHAIN_RAW"
  # Module hash prints as "Module hash: 0x<hex>".
  ONCHAIN_HASH="$(printf '%s\n' "$ONCHAIN_RAW" | sed -n 's/.*[Mm]odule hash: *0x\([0-9a-fA-F]*\).*/\1/p')"
  if [[ -z "$ONCHAIN_HASH" ]]; then
    echo "Could not parse a module hash from dfx output." >&2
    exit 1
  fi
  echo ""
  if [[ "$LOCAL_HASH" == "$ONCHAIN_HASH" ]]; then
    echo "MATCH: on-chain module_hash == rebuilt wasm"
    echo "  -> the deployed canister runs this exact source."
  else
    echo "MISMATCH: on-chain module_hash = $ONCHAIN_HASH" >&2
    echo "          rebuilt wasm        = $LOCAL_HASH" >&2
    echo "The live canister does NOT run this commit's source (or it was built" >&2
    echo "with a different toolchain). Check out the deployed commit and retry." >&2
    exit 1
  fi
fi
