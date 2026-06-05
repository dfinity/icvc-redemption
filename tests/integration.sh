#!/usr/bin/env bash
# Integration smoke tests for the redemption canister.
#
# Runs against the icp-cli local network. Assumes `bash scripts/deploy.sh -e local`
# has already been run (canisters present, ledgers funded, seed data applied,
# admin = the current `icp identity` default principal).
#
# Usage:
#   bash tests/integration.sh                          # full default suite
#   bash tests/integration.sh --case redeem            # filter by substring
#
# The suite is idempotent across runs (state-mutating cases clean up after
# themselves).
#
# Exit code: 0 if all assertions pass, non-zero count = failures.

set -uo pipefail

# ---- Plumbing ----------------------------------------------------------------

PASS=0
FAIL=0
RED='\033[31m'
GREEN='\033[32m'
DIM='\033[2m'
RESET='\033[0m'

CASE_FILTER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --case) CASE_FILTER="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 2 ;;
    esac
done

ENV=local

# Update call against the default identity. `icp canister call` prompts for
# confirmation by default and has no --yes flag, so we pipe `y` via stdin.
# (Queries ignore the prompt, so piping `y` is harmless on those too.)
icp_call() {
    echo y | icp canister call -e "$ENV" "$@" 2>&1
}

# Update call against a specific identity.
icp_call_id() {
    local id="$1"; shift
    echo y | icp canister call -e "$ENV" --identity "$id" "$@" 2>&1
}

run_case() {
    local name="$1"
    local fn="$2"
    if [[ -n "$CASE_FILTER" && "$name" != *"$CASE_FILTER"* ]]; then return 0; fi
    printf "${DIM}  %s${RESET}\n" "$name"
    if $fn; then
        PASS=$((PASS+1))
        printf "${GREEN}✓ %s${RESET}\n" "$name"
    else
        FAIL=$((FAIL+1))
        printf "${RED}✗ %s${RESET}\n" "$name"
    fi
}

expect_contains() {
    local description="$1"
    local actual="$2"
    local needle="$3"
    if [[ "$actual" == *"$needle"* ]]; then
        return 0
    fi
    printf "    ${RED}assertion failed: %s${RESET}\n" "$description"
    printf "    expected to contain: ${DIM}%s${RESET}\n" "$needle"
    printf "    got: ${DIM}%s${RESET}\n" "$actual"
    return 1
}

# ---- Pre-flight --------------------------------------------------------------

if ! icp network ping local >/dev/null 2>&1; then
    echo "Error: icp-cli local network not running. Start it with:"
    echo "  icp network start local --background"
    echo "Or just run: bash scripts/deploy.sh -e local"
    exit 1
fi

canister_id() {
    local name="$1"
    python3 -c "
import json
with open('.icp/cache/mappings/${ENV}.ids.json') as f:
    print(json.load(f)['${name}'])
"
}

REDEMPTION_ID=$(canister_id redemption 2>/dev/null) || {
    echo "Error: redemption canister not deployed. Run: bash scripts/deploy.sh -e local"
    exit 1
}
ICVC_ID=$(canister_id icvc_ledger)
ICP_ID=$(canister_id icp_ledger)
DEPLOYER=$(icp identity principal)

approve_icvc() {
    local amount="$1"
    local id="${2:-}"
    local approve_args="(record {
      from_subaccount = null;
      spender = record { owner = principal \"$REDEMPTION_ID\"; subaccount = null };
      amount = $amount : nat;
      expected_allowance = null;
      expires_at = null;
      fee = null;
      memo = null;
      created_at_time = null;
    })"
    if [[ -n "$id" ]]; then
        echo y | icp canister call -e "$ENV" --identity "$id" icvc_ledger icrc2_approve "$approve_args" >/dev/null
    else
        echo y | icp canister call -e "$ENV" icvc_ledger icrc2_approve "$approve_args" >/dev/null
    fi
}

parse_nat() {
    echo "$1" | tr -dc '0-9'
}

balance_of() {
    local ledger="$1"
    local principal="$2"
    parse_nat "$(icp_call "$ledger" icrc1_balance_of \
        "(record { owner = principal \"$principal\"; subaccount = null })" --query)"
}

# Ensure a `test-admin` identity exists for two-principal scenarios.
if ! icp identity list 2>&1 | grep -q "test-admin"; then
    icp identity new test-admin --storage plaintext --quiet >/dev/null 2>&1
fi
TEST_ADMIN_PRINCIPAL=$(icp identity principal --identity test-admin)

# Seed test-admin with cycles + ICP if needed (icp-cli's local network seeds
# the principal that was default at network-start time; created-later
# identities start with zero ICP and cycles).
if [[ "$(icp token balance -e "$ENV" --identity test-admin 2>&1 | tr -dc '0-9.')" == "0.00000000" ]] \
   || [[ "$(icp token balance -e "$ENV" --identity test-admin 2>&1 | grep -c '^Balance: 0')" -gt 0 ]]; then
    # Transfer 10 ICP from the deployer so test-admin can pay ledger fees if
    # asked to (the integration suite generally has the deployer fund it via
    # the faucet, but the helper exists for completeness).
    echo y | icp token transfer 10 "$TEST_ADMIN_PRINCIPAL" -e "$ENV" >/dev/null 2>&1 || true
fi

# ---- Cases -------------------------------------------------------------------

case_listAdmins_includes_deployer() {
    local out
    out=$(icp_call redemption listAdmins)
    expect_contains "deployer in admin list" "$out" "$DEPLOYER"
}

case_faucet_then_cooldown() {
    # We can't reset faucet state between runs without a fresh deploy; this
    # case assumes the cooldown may or may not be active. We assert that the
    # second call returns either ok or a cooldown error (not a crash).
    icp_call redemption faucet >/dev/null 2>&1 || true
    local out
    out=$(icp_call redemption faucet)
    if [[ "$out" == *"Faucet cooldown"* || "$out" == *"variant { ok"* ]]; then
        return 0
    fi
    expect_contains "faucet returned cooldown or ok" "$out" "Faucet cooldown"
}

case_anonymous_redeem_rejected() {
    # Anonymous callers are blocked twice (defense in depth):
    #   1) `canister_inspect_message` drops the ingress before any update
    #      cycles run -> "canister_inspect_message explicitly refused".
    #   2) The body returns `#NotAuthorized` if any caller reaches it.
    # Anonymous can't fetch candid, so variants come back hashed
    # (`NotAuthorized` -> 2_102_411_630).
    local out
    out=$(icp_call_id anonymous redemption redeem '(1_000_000_000 : nat)' 2>&1)
    if [[ "$out" == *"canister_inspect_message explicitly refused"* ]] \
       || [[ "$out" == *"NotAuthorized"* ]] \
       || [[ "$out" == *"2_102_411_630"* ]]; then
        return 0
    fi
    printf "    ${RED}neither ingress-reject nor body-reject seen${RESET}\n"
    printf "    ${DIM}%s${RESET}\n" "$out"
    return 1
}

case_happy_path_redeem() {
    approve_icvc 10_000_000_000
    local out
    out=$(icp_call redemption redeem '(1_000_000_000 : nat)')
    expect_contains "happy-path redeem succeeds" "$out" "ok = record"
}

case_concurrent_redeem_rejected() {
    approve_icvc 10_000_000_000
    # Fire two in parallel; one should win, one should be rejected by CallerGuard.
    icp_call redemption redeem '(1_000_000_000 : nat)' >/tmp/icvc_a.txt 2>&1 &
    icp_call redemption redeem '(1_000_000_000 : nat)' >/tmp/icvc_b.txt 2>&1 &
    wait
    local both
    both=$(cat /tmp/icvc_a.txt /tmp/icvc_b.txt)
    expect_contains "one call rejected with ConcurrentRedemption" "$both" "ConcurrentRedemption"
}

case_getInFlight_empty_after_happy_path() {
    local out
    out=$(icp_call redemption getInFlight)
    expect_contains "getInFlight empty after success" "$out" "vec {}"
}

case_getInFlight_public() {
    # getInFlight is public (the saga journal is auditable by anyone): an
    # anonymous caller gets the list (a vec), not NotAuthorized. Anonymous
    # must pass args explicitly; an empty vec renders as `vec {}` either way.
    local out
    out=$(icp_call_id anonymous redemption getInFlight '()' --query)
    if [[ "$out" == *"vec"* && "$out" != *"NotAuthorized"* && "$out" != *"2_102_411_630"* ]]; then
        return 0
    fi
    printf "    ${RED}getInFlight not publicly readable: %s${RESET}\n" "$out"
    return 1
}

case_retryRefund_unknown_id_clean_error() {
    local out
    out=$(icp_call redemption retryRefund '(999999 : nat)')
    expect_contains "retryRefund unknown id -> not found" "$out" "No in-flight"
}

case_forceCloseInFlight_admin_only() {
    # Two-layer rejection (defense in depth):
    #   1) inspect_message drops anonymous at ingress.
    #   2) Body returns `err = "Not authorized"` if reached.
    # Either is an acceptable outcome.
    local out
    out=$(icp_call_id anonymous redemption forceCloseInFlight '(0 : nat)' 2>&1)
    if [[ "$out" == *"canister_inspect_message explicitly refused"* ]] \
       || [[ "$out" == *"Not authorized"* ]]; then
        return 0
    fi
    printf "    ${RED}neither ingress-reject nor body-reject seen${RESET}\n"
    printf "    ${DIM}%s${RESET}\n" "$out"
    return 1
}

# ============================================================================
# Phase 2 cases: financial correctness, error paths, admin allowlist, ledger
# tx inspection, upgrade preservation, lock release on error.
# ============================================================================

case_faucet_delivers_icvc() {
    local before after expected_delta floor
    before=$(balance_of icvc_ledger "$TEST_ADMIN_PRINCIPAL")
    icp_call_id test-admin redemption faucet '()' >/dev/null 2>&1 || true
    after=$(balance_of icvc_ledger "$TEST_ADMIN_PRINCIPAL")
    expected_delta=1000000000000  # 10_000 ICVC e8s (faucet amount)
    # "Already faucetted" tolerance: balances drift downward by fees as later
    # tests do redeems. Treat >= 90% of expected_delta as already-faucetted.
    floor=900000000000
    if [[ $((after - before)) -ge $expected_delta ]]; then
        return 0
    fi
    if [[ "$before" -ge "$floor" ]]; then
        return 0
    fi
    printf "    ${RED}faucet delta too small: before=%s after=%s${RESET}\n" "$before" "$after"
    return 1
}

case_redeem_delivers_icp() {
    # ICRC transfer fees come out of the sender's balance (the canister),
    # so the recipient receives the full payout amount.
    approve_icvc 10_000_000_000
    local icp_before icp_after icp_payout
    icp_before=$(balance_of icp_ledger "$DEPLOYER")
    icp_call redemption redeem '(1_000_000_000 : nat)' >/dev/null
    icp_after=$(balance_of icp_ledger "$DEPLOYER")
    icp_payout=57530220             # 1_000_000_000 * 5_753_022 / 1e8 (fair-value rate)
    local delta=$((icp_after - icp_before))
    if [[ "$delta" -eq "$icp_payout" ]]; then
        return 0
    fi
    printf "    ${RED}ICP delta wrong: expected=%s delta=%s${RESET}\n" "$icp_payout" "$delta"
    return 1
}

case_redeem_burns_icvc() {
    # Redeemed ICVC is burned (sent to the minting account) as the final step.
    # Strong, feature-specific checks: total_icvc_burned rises by exactly the
    # redeemed amount, and the canister's ICVC balance is unchanged (it pulled
    # `amount` then burned `amount`, so the faucet reserve is untouched). Supply
    # also drops by at least `amount` (the burn; plus the burned transfer fee).
    approve_icvc 10_000_000_000
    local amount=1000000000
    local supply_before burned_before canbal_before
    supply_before=$(parse_nat "$(icp_call icvc_ledger icrc1_total_supply '()' --query)")
    burned_before=$(parse_nat "$(icp_call redemption getStats | grep total_icvc_burned)")
    canbal_before=$(balance_of icvc_ledger "$REDEMPTION_ID")
    icp_call redemption redeem "($amount : nat)" >/dev/null
    local supply_after burned_after canbal_after
    supply_after=$(parse_nat "$(icp_call icvc_ledger icrc1_total_supply '()' --query)")
    burned_after=$(parse_nat "$(icp_call redemption getStats | grep total_icvc_burned)")
    canbal_after=$(balance_of icvc_ledger "$REDEMPTION_ID")
    local burned_rise=$((burned_after - burned_before))
    local canbal_delta=$((canbal_after - canbal_before))
    local supply_drop=$((supply_before - supply_after))
    if [[ "$burned_rise" -eq "$amount" && "$canbal_delta" -eq 0 && "$supply_drop" -ge "$amount" ]]; then
        return 0
    fi
    printf "    ${RED}burn check: burned_rise=%s (want %s) canbal_delta=%s (want 0) supply_drop=%s (want >=%s)${RESET}\n" \
        "$burned_rise" "$amount" "$canbal_delta" "$supply_drop" "$amount"
    return 1
}

case_sweepBurn_admin_noop() {
    # Inline burns leave nothing pending, so an admin sweep is a no-op (ok = 0).
    # Also confirms the method exists and is admin-callable as the deployer.
    local out
    out=$(icp_call redemption sweepBurn '()')
    expect_contains "admin sweepBurn no-op returns ok = 0" "$out" "ok = 0"
}

case_getPendingBurns_public() {
    # getPendingBurns is public; normally empty (inline burns succeed). Returns
    # a vec directly (no Result wrapper). Anonymous can read it too.
    local out
    out=$(icp_call_id anonymous redemption getPendingBurns '()' --query)
    if [[ "$out" == *"vec"* && "$out" != *"NotAuthorized"* && "$out" != *"2_102_411_630"* ]]; then
        return 0
    fi
    printf "    ${RED}getPendingBurns not publicly readable: %s${RESET}\n" "$out"
    return 1
}

case_below_minimum_redeem() {
    # MIN_REDEMPTION is 10 ICVC (1_000_000_000 e8s). 999_999_999 is exactly
    # 1 e8s below that, the strictest boundary case.
    local out
    out=$(icp_call redemption redeem '(999_999_999 : nat)')
    expect_contains "redeem below MIN_REDEMPTION -> #BelowMinimum" "$out" "BelowMinimum"
}

case_paused_redeem_rejected() {
    icp_call redemption pause >/dev/null
    local out
    out=$(icp_call redemption redeem '(1_000_000_000 : nat)')
    icp_call redemption unpause >/dev/null
    expect_contains "redeem while paused -> #Paused" "$out" "Paused"
}

case_paused_faucet_rejected() {
    # Pause halts ALL trading: redeem AND the test-token faucet. retryRefund
    # stays available so users can recover stuck redemptions during a halt.
    icp_call redemption pause >/dev/null
    local out
    out=$(icp_call_id test-admin redemption faucet '()')
    icp_call redemption unpause >/dev/null
    expect_contains "faucet while paused" "$out" "Canister is paused"
}

case_pause_unpause_cycle_resumes_redeem() {
    # Same idea as the redeem-paused test, but explicit about the resume.
    icp_call redemption pause >/dev/null
    local paused_out
    paused_out=$(icp_call redemption redeem '(1_000_000_000 : nat)')
    icp_call redemption unpause >/dev/null
    approve_icvc 10_000_000_000
    local resumed_out
    resumed_out=$(icp_call redemption redeem '(1_000_000_000 : nat)')
    if [[ "$paused_out" == *"Paused"* && "$resumed_out" == *"ok = record"* ]]; then
        return 0
    fi
    printf "    ${RED}pause/unpause cycle failed${RESET}\n"
    printf "    ${DIM}paused:  %s${RESET}\n" "$paused_out"
    printf "    ${DIM}resumed: %s${RESET}\n" "$resumed_out"
    return 1
}

case_anonymous_public_queries_work() {
    # The frontend page-loads as anonymous and reads getStats /
    # getRedemptionHistory / getExchangeRate. These MUST stay callable
    # without authentication or the frontend never gets past its spinner.
    local stats history rate
    stats=$(icp_call_id anonymous redemption getStats '()')
    history=$(icp_call_id anonymous redemption getRedemptionHistory '(0 : nat, 5 : nat)' --query)
    rate=$(icp_call_id anonymous redemption getExchangeRate '()' --query)
    # getStats responds as a record. Anonymous can't fetch candid so the
    # field names come through hashed; spot-check by looking for the
    # exchange_rate_e8s literal (5_753_022, the fair-value-derived rate),
    # which is a Nat constant that survives intact, plus the record envelope
    # so we know the response was a struct rather than an error.
    if [[ "$stats" == *"5_753_022"* && "$stats" == *"record"* ]] \
       && [[ "$history" == *"record"* || "$history" == *"vec {}"* ]] \
       && [[ "$rate" == *"5_753_022"* ]]; then
        return 0
    fi
    printf "    ${RED}anonymous read failed somewhere${RESET}\n"
    printf "    ${DIM}stats:   %s${RESET}\n" "$stats"
    printf "    ${DIM}history: %s${RESET}\n" "$history"
    printf "    ${DIM}rate:    %s${RESET}\n" "$rate"
    return 1
}

case_getExchangeRate_is_a_query() {
    # Regression guard: getExchangeRate is annotated `query`, so --query
    # works without the canister upgrading the call to an update. If
    # someone changes it to an update method, this test fails.
    local out
    out=$(icp canister call -e local redemption getExchangeRate '()' --query 2>&1)
    if [[ "$out" == *"5_753_022"* ]]; then
        return 0
    fi
    expect_contains "getExchangeRate returns the derived rate as a query" "$out" "5_753_022"
}

case_getMyInFlight_filters_caller() {
    # getMyInFlight uses the implicit `caller`; called by two different
    # principals, each must see only their own entries (which today, on
    # the happy path, is none — both should be empty vec).
    local deployer_out test_admin_out
    deployer_out=$(icp_call redemption getMyInFlight '()' --query)
    test_admin_out=$(icp_call_id test-admin redemption getMyInFlight '()' --query)
    # Both should be empty (or contain only entries belonging to the
    # caller). We assert no entry shows the OTHER principal.
    local deployer_principal test_admin_principal
    deployer_principal="$DEPLOYER"
    test_admin_principal="$TEST_ADMIN_PRINCIPAL"
    if [[ "$deployer_out" == *"$test_admin_principal"* ]]; then
        printf "    ${RED}deployer saw test-admin entries${RESET}\n%s\n" "$deployer_out"
        return 1
    fi
    if [[ "$test_admin_out" == *"$deployer_principal"* ]]; then
        printf "    ${RED}test-admin saw deployer entries${RESET}\n%s\n" "$test_admin_out"
        return 1
    fi
    return 0
}

case_forceCloseInFlight_admin_happy_path() {
    # Manufacturing a real in-flight entry deterministically requires
    # triggering an ICP-transfer failure mid-flow, which we can't do
    # cleanly without test-only hooks. Substitute: assert that admin
    # forceCloseInFlight against an unknown id returns a not-found error
    # rather than NotAuthorized. The fact that we see the not-found error
    # proves the auth check has already passed for the admin.
    local out
    out=$(icp_call redemption forceCloseInFlight '(99999 : nat)')
    if [[ "$out" == *"No in-flight entry with id 99999"* ]]; then
        return 0
    fi
    expect_contains "admin forceClose unknown id -> not found (auth passed)" "$out" "No in-flight"
}

case_getExchangeRate_matches_derived_rate() {
    local rate
    rate=$(parse_nat "$(icp_call redemption getExchangeRate)")
    if [[ "$rate" == "5753022" ]]; then
        return 0
    fi
    printf "    ${RED}exchange rate not the derived 5_753_022: got %s${RESET}\n" "$rate"
    return 1
}

case_getFairValueInputs_derives_rate() {
    # getFairValueInputs exposes the treasury-backing inputs and the derived
    # rate. Verify the snapshot constants and that the derived rate matches
    # getExchangeRate (5_753_022). Anonymous-readable like getStats.
    local out
    out=$(icp_call_id anonymous redemption getFairValueInputs '()' --query)
    if [[ "$out" == *"5_753_022"* ]] \
       && [[ "$out" == *"1_999_998_744_500_000"* ]] \
       && [[ "$out" == *"36_914_604_063_259"* ]]; then
        return 0
    fi
    printf "    ${RED}getFairValueInputs missing expected derived values${RESET}\n%s\n" "$out"
    return 1
}

case_setExchangeRate_method_removed() {
    local out
    out=$(icp_call redemption setExchangeRate '(1 : nat)')
    if [[ "$out" == *"setExchangeRate"* && "$out" == *"has no update method"* ]] \
       || [[ "$out" == *"no update method"* ]] \
       || [[ "$out" == *"not found"* ]] \
       || [[ "$out" == *"WrongMethod"* ]] \
       || [[ "$out" == *"NotFound"* ]]; then
        return 0
    fi
    if [[ "$out" == *"ok"* && "$out" != *"err"* ]]; then
        printf "    ${RED}setExchangeRate still callable (H2 regression)${RESET}\n"
        printf "    ${DIM}%s${RESET}\n" "$out"
        return 1
    fi
    return 0
}

case_stats_total_icvc_redeemed_increments() {
    approve_icvc 10_000_000_000
    local before redeemed_amount after
    before=$(parse_nat "$(icp_call redemption getStats | grep total_icvc_redeemed)")
    redeemed_amount=1000000000
    icp_call redemption redeem '(1_000_000_000 : nat)' >/dev/null
    after=$(parse_nat "$(icp_call redemption getStats | grep total_icvc_redeemed)")
    local delta=$((after - before))
    if [[ "$delta" -eq "$redeemed_amount" ]]; then
        return 0
    fi
    printf "    ${RED}total_icvc_redeemed delta wrong: expected=%s delta=%s${RESET}\n" "$redeemed_amount" "$delta"
    return 1
}

case_addAdmin_happy_then_remove() {
    local listed_before listed_after
    listed_before=$(icp_call redemption listAdmins | grep -c "principal")
    icp_call redemption addAdmin "(principal \"$TEST_ADMIN_PRINCIPAL\")" >/dev/null
    listed_after=$(icp_call redemption listAdmins | grep -c "principal")
    icp_call redemption removeAdmin "(principal \"$TEST_ADMIN_PRINCIPAL\")" >/dev/null 2>&1
    if [[ "$listed_after" -eq $((listed_before + 1)) ]]; then
        return 0
    fi
    printf "    ${RED}admin count wrong: before=%s after=%s${RESET}\n" "$listed_before" "$listed_after"
    return 1
}

case_addAdmin_existing_rejected() {
    local out
    out=$(icp_call redemption addAdmin "(principal \"$DEPLOYER\")")
    expect_contains "addAdmin existing -> error" "$out" "Already an admin"
}

case_removeAdmin_unknown_rejected() {
    local out
    out=$(icp_call redemption removeAdmin "(principal \"aaaaa-aa\")")
    expect_contains "removeAdmin unknown -> error" "$out" "Not an admin"
}

case_removeAdmin_last_admin_lockout() {
    local out
    out=$(icp_call redemption removeAdmin "(principal \"$DEPLOYER\")")
    expect_contains "remove last admin -> lockout guard" "$out" "Cannot remove the last admin"
}

case_multi_principal_parallel_both_succeed() {
    icp_call_id test-admin redemption faucet '()' >/dev/null 2>&1 || true
    approve_icvc 10_000_000_000
    approve_icvc 10_000_000_000 test-admin
    icp_call redemption redeem '(1_000_000_000 : nat)' >/tmp/icvc_d.txt 2>&1 &
    icp_call_id test-admin redemption redeem '(1_000_000_000 : nat)' >/tmp/icvc_t.txt 2>&1 &
    wait
    local both ok_count
    both=$(cat /tmp/icvc_d.txt /tmp/icvc_t.txt)
    # `ok = record` is the symbolic form; `24_860 = record` is the hash-encoded
    # form icp-cli renders when the caller can't fetch the candid metadata
    # (24_860 is the field-name hash of "ok"). Both forms indicate success.
    ok_count=$(echo "$both" | grep -cE 'ok = record|24_860 = record')
    if [[ "$ok_count" -eq 2 ]]; then
        return 0
    fi
    printf "    ${RED}expected 2 successful redeems, got %s${RESET}\n" "$ok_count"
    printf "    ${DIM}deployer:\n%s\ntest-admin:\n%s${RESET}\n" "$(cat /tmp/icvc_d.txt)" "$(cat /tmp/icvc_t.txt)"
    return 1
}

case_ledger_tx_has_memo_and_created_at_time() {
    # Do a fresh approve+redeem, then scan the tail of the ledger log for ANY
    # transaction whose memo matches our "redemption-N" format. We don't pin
    # to the very last tx because prior cases in this run may have left a
    # faucet/approve tx as the most recent.
    approve_icvc 10_000_000_000
    icp_call redemption redeem '(1_000_000_000 : nat)' >/dev/null
    local log_length start
    log_length=$(parse_nat "$(icp_call icvc_ledger get_transactions \
        '(record { start = 0 : nat; length = 0 : nat })' --query | grep log_length)")
    # Scan the most recent 10 txs.
    start=$(( log_length > 10 ? log_length - 10 : 0 ))
    local out
    out=$(icp_call icvc_ledger get_transactions \
        "(record { start = $start : nat; length = 10 : nat })" --query)
    if [[ "$out" == *'memo = opt blob "redemption-'* && "$out" == *"created_at_time = opt"* ]]; then
        return 0
    fi
    printf "    ${RED}no recent ledger tx has memo + created_at_time${RESET}\n"
    printf "    ${DIM}%s${RESET}\n" "$out"
    return 1
}

case_getRedemptionHistory_pagination() {
    local out count
    out=$(icp_call redemption getRedemptionHistory '(0 : nat, 1 : nat)')
    count=$(echo "$out" | grep -c "user = principal")
    if [[ "$count" -eq 1 ]]; then
        return 0
    fi
    printf "    ${RED}pagination yielded %s records, expected 1${RESET}\n" "$count"
    return 1
}

case_getRedemptionLog_unified() {
    # Unified log includes completed redemptions with a #Completed status, and
    # is public (anonymous can read it). A successful redeem must show up.
    approve_icvc 10_000_000_000
    icp_call redemption redeem '(1_000_000_000 : nat)' >/dev/null
    local out anon
    out=$(icp_call redemption getRedemptionLog '(0 : nat, 10 : nat)' --query)
    anon=$(icp_call_id anonymous redemption getRedemptionLog '(0 : nat, 10 : nat)' --query)
    # Named call shows the Completed variant; anon (no candid) still returns a vec.
    if [[ "$out" == *"Completed"* && "$out" == *"record"* ]] \
       && [[ "$anon" == *"vec"* && "$anon" != *"NotAuthorized"* ]]; then
        return 0
    fi
    printf "    ${RED}getRedemptionLog missing Completed entry or not public${RESET}\n%s\n" "$out"
    return 1
}

case_getUserRedemptions_filters_caller() {
    local out wrong_owner
    out=$(icp_call redemption getUserRedemptions "(principal \"$DEPLOYER\", 0 : nat, 100 : nat)")
    wrong_owner=$(echo "$out" | grep -E '^\s*user = principal' | grep -v "$DEPLOYER" | wc -l | tr -d ' ')
    if [[ "$wrong_owner" -eq 0 ]]; then
        return 0
    fi
    printf "    ${RED}getUserRedemptions leaked %s entries for other users${RESET}\n" "$wrong_owner"
    return 1
}

case_getUserRedemptions_pagination_limit() {
    local out count
    out=$(icp_call redemption getUserRedemptions "(principal \"$DEPLOYER\", 0 : nat, 1 : nat)")
    count=$(echo "$out" | grep -c "user = principal")
    if [[ "$count" -le 1 ]]; then
        return 0
    fi
    printf "    ${RED}limit=1 yielded %s records${RESET}\n" "$count"
    return 1
}

case_getUserRedemptions_pagination_offset() {
    local first_id offset_id second_id
    first_id=$(icp_call redemption getUserRedemptions "(principal \"$DEPLOYER\", 0 : nat, 2 : nat)" \
        | grep -m1 -E '^\s*id =' | tr -dc '0-9')
    second_id=$(icp_call redemption getUserRedemptions "(principal \"$DEPLOYER\", 0 : nat, 2 : nat)" \
        | grep -E '^\s*id =' | sed -n '2p' | tr -dc '0-9')
    offset_id=$(icp_call redemption getUserRedemptions "(principal \"$DEPLOYER\", 1 : nat, 1 : nat)" \
        | grep -m1 -E '^\s*id =' | tr -dc '0-9')
    if [[ "$offset_id" == "$second_id" && "$first_id" != "$offset_id" ]]; then
        return 0
    fi
    printf "    ${RED}offset=1 yielded id=%s; expected second-newest=%s (newest=%s)${RESET}\n" \
        "$offset_id" "$second_id" "$first_id"
    return 1
}

case_upgrade_preserves_state() {
    local before_admins after_admins before_count after_count
    icp_call redemption addAdmin "(principal \"$TEST_ADMIN_PRINCIPAL\")" >/dev/null
    before_admins=$(icp_call redemption listAdmins | grep -c "principal")
    before_count=$(parse_nat "$(icp_call redemption getStats | grep total_redemptions)")

    icp canister install redemption -e "$ENV" --mode upgrade --yes --args "(record {
        icvc_ledger_id = principal \"$ICVC_ID\";
        icp_ledger_id = principal \"$ICP_ID\";
        admin = principal \"$DEPLOYER\";
    })" >/dev/null 2>&1

    after_admins=$(icp_call redemption listAdmins | grep -c "principal")
    after_count=$(parse_nat "$(icp_call redemption getStats | grep total_redemptions)")
    icp_call redemption removeAdmin "(principal \"$TEST_ADMIN_PRINCIPAL\")" >/dev/null 2>&1
    if [[ "$after_admins" -eq "$before_admins" && "$after_count" -eq "$before_count" ]]; then
        return 0
    fi
    printf "    ${RED}state lost on upgrade: admins %s->%s, count %s->%s${RESET}\n" \
        "$before_admins" "$after_admins" "$before_count" "$after_count"
    return 1
}

case_lock_released_after_error_path() {
    # Reset allowance to zero, then attempt redeem -> TransferFromFailed.
    icp_call icvc_ledger icrc2_approve "(record {
      from_subaccount = null;
      spender = record { owner = principal \"$REDEMPTION_ID\"; subaccount = null };
      amount = 0 : nat; expected_allowance = null; expires_at = null;
      fee = null; memo = null; created_at_time = null;
    })" >/dev/null
    local first_out
    first_out=$(icp_call redemption redeem '(1_000_000_000 : nat)')
    # If the lock leaked, the next call returns ConcurrentRedemption; we expect ok.
    approve_icvc 10_000_000_000
    local second_out
    second_out=$(icp_call redemption redeem '(1_000_000_000 : nat)')
    if [[ "$first_out" == *"TransferFromFailed"* && "$second_out" == *"ok = record"* ]]; then
        return 0
    fi
    printf "    ${RED}lock-release test failed${RESET}\n"
    printf "    ${DIM}first (should be TransferFromFailed): %s${RESET}\n" "$first_out"
    printf "    ${DIM}second (should be ok): %s${RESET}\n" "$second_out"
    return 1
}

# ---- Run ---------------------------------------------------------------------

echo "=== Integration smoke suite (icp-cli) ==="
echo "Redemption:  $REDEMPTION_ID"
echo "Deployer:    $DEPLOYER"
echo ""

run_case "listAdmins includes deployer"          case_listAdmins_includes_deployer
run_case "faucet cooldown returns or succeeds"   case_faucet_then_cooldown
run_case "anonymous redeem rejected"             case_anonymous_redeem_rejected
run_case "happy-path redeem"                     case_happy_path_redeem
run_case "concurrent redeem -> ConcurrentRedemption" case_concurrent_redeem_rejected
run_case "getInFlight empty after success"       case_getInFlight_empty_after_happy_path
run_case "getInFlight is public"                  case_getInFlight_public
run_case "retryRefund unknown id clean error"    case_retryRefund_unknown_id_clean_error
run_case "forceCloseInFlight admin-only"         case_forceCloseInFlight_admin_only
run_case "faucet delivers ICVC to balance"       case_faucet_delivers_icvc
run_case "redeem delivers ICP to balance"        case_redeem_delivers_icp
run_case "redeem burns redeemed ICVC"            case_redeem_burns_icvc
run_case "sweepBurn admin no-op"                 case_sweepBurn_admin_noop
run_case "getPendingBurns is public"               case_getPendingBurns_public
run_case "below MIN_REDEMPTION -> #BelowMinimum" case_below_minimum_redeem
run_case "paused redeem -> #Paused"              case_paused_redeem_rejected
run_case "paused faucet -> rejected"             case_paused_faucet_rejected
run_case "pause/unpause cycle resumes redeem"    case_pause_unpause_cycle_resumes_redeem
run_case "anonymous public queries work"         case_anonymous_public_queries_work
run_case "getExchangeRate is a query"            case_getExchangeRate_is_a_query
run_case "getMyInFlight filters caller"          case_getMyInFlight_filters_caller
run_case "forceCloseInFlight admin happy path"   case_forceCloseInFlight_admin_happy_path
run_case "getExchangeRate matches derived fair-value rate" case_getExchangeRate_matches_derived_rate
run_case "getFairValueInputs derives the rate"   case_getFairValueInputs_derives_rate
run_case "setExchangeRate method is gone (H2)"        case_setExchangeRate_method_removed
run_case "getStats.total_icvc_redeemed increments" case_stats_total_icvc_redeemed_increments
run_case "addAdmin happy path then removeAdmin"  case_addAdmin_happy_then_remove
run_case "addAdmin existing -> rejected"         case_addAdmin_existing_rejected
run_case "removeAdmin unknown -> rejected"       case_removeAdmin_unknown_rejected
run_case "removeAdmin last admin -> lockout"     case_removeAdmin_last_admin_lockout
run_case "multi-principal parallel both succeed" case_multi_principal_parallel_both_succeed
run_case "ledger tx has memo + created_at_time"  case_ledger_tx_has_memo_and_created_at_time
run_case "getRedemptionHistory pagination"       case_getRedemptionHistory_pagination
run_case "getRedemptionLog unified + public"     case_getRedemptionLog_unified
run_case "getUserRedemptions filters caller"     case_getUserRedemptions_filters_caller
run_case "getUserRedemptions paginates (limit)"  case_getUserRedemptions_pagination_limit
run_case "getUserRedemptions paginates (offset)" case_getUserRedemptions_pagination_offset
run_case "upgrade preserves admins + count"      case_upgrade_preserves_state
run_case "lock released after TransferFromFailed" case_lock_released_after_error_path

echo ""
echo "Passed: $PASS    Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
