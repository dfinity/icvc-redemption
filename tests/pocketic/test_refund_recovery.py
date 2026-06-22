"""Refund / burn recovery paths that need a fault-injecting ICVC ledger.

Builds on `mock_ledger.mo` (runtime-toggleable `icrc1_transfer`) installed as
BOTH ledgers, so we can fail the in-line refund / burn first and then succeed
on retry — the last recovery gaps the bash suite and the ICP-only mock can't
reach. Also exercises `getDedupKey` and `forceCloseInFlight` against a *real*
stuck entry.

No faucet/approve needed: the mock's `icrc2_transfer_from` (the pull) always
succeeds and moves nothing, so these tests drive the saga branches directly.
"""

from ic.candid import Types, decode, encode
from conftest import ALICE, DEPLOYER, make_mock_deployment


def candid_hash(name: str) -> int:
    h = 0
    for b in name.encode():
        h = (h * 223 + b) & 0xFFFFFFFF
    return h


def _nat_args(n: int):
    return [{"type": Types.Nat, "value": n}]


def _get_inflight(d):
    d.pic.set_anonymous_sender()
    return decode(d.pic.query_call(d.redemption, "getInFlight", encode([])))[0]["value"]


def _get_stats(d):
    d.pic.set_anonymous_sender()
    return decode(d.pic.update_call(d.redemption, "getStats", encode([])))[0]["value"]


def _set_transfer_fail_mode(d, ledger, mode: int):
    d.pic.set_anonymous_sender()  # the mock's setter is unauthenticated
    d.pic.update_call(ledger, "setTransferFailMode", encode(_nat_args(mode)))


AMOUNT = 100 * 100_000_000  # 100 ICVC


def test_retry_refund_happy_path(pic, redemption_wasm, mock_ledger_wasm):
    # ICVC refund fails (mode 1) and ICP payout fails cleanly (mode 1), so the
    # redeem does an in-line refund that also fails -> entry parks in
    # #RefundPending (the only state retryRefund will auto-refund).
    d = make_mock_deployment(
        pic, redemption_wasm, mock_ledger_wasm,
        icvc_transfer_mode=1, icp_transfer_mode=1,
    )
    d.pic.set_sender(ALICE)
    decode(d.pic.update_call(d.redemption, "redeem", encode(_nat_args(AMOUNT))))

    entries = _get_inflight(d)
    assert len(entries) == 1, f"expected one in-flight entry, got {entries!r}"
    assert f"_{candid_hash('RefundPending')}" in entries[0][f"_{candid_hash('status')}"], (
        f"expected #RefundPending, got {entries[0]!r}"
    )
    entry_id = entries[0][f"_{candid_hash('id')}"]

    # getDedupKey (admin) returns the pinned created_at_time for reconciliation.
    d.pic.set_sender(DEPLOYER)
    dedup = decode(d.pic.update_call(d.redemption, "getDedupKey", encode(_nat_args(entry_id))))[0]["value"]
    ok = dedup.get(f"_{candid_hash('ok')}")
    assert ok is not None and len(ok) == 1, f"getDedupKey should return ok(?key), got {dedup!r}"

    # Heal the ICVC ledger, then retryRefund succeeds and clears the entry.
    _set_transfer_fail_mode(d, d.icvc_ledger, 0)
    d.pic.set_sender(ALICE)
    retry = decode(d.pic.update_call(d.redemption, "retryRefund", encode(_nat_args(entry_id))))[0]["value"]
    assert f"_{candid_hash('ok')}" in retry, f"retryRefund should succeed, got {retry!r}"
    assert _get_inflight(d) == [], "entry should be removed after a successful refund"


def test_sweep_burn_flush(pic, redemption_wasm, mock_ledger_wasm):
    # ICP payout succeeds (mode 0) so the redeem completes, but the burn (ICVC
    # transfer to minting) fails (mode 1) -> amount parks in pendingBurns.
    d = make_mock_deployment(
        pic, redemption_wasm, mock_ledger_wasm,
        icvc_transfer_mode=1, icp_transfer_mode=0,
    )
    d.pic.set_sender(ALICE)
    result = decode(d.pic.update_call(d.redemption, "redeem", encode(_nat_args(AMOUNT))))[0]["value"]
    assert f"_{candid_hash('ok')}" in result, f"redeem should succeed, got {result!r}"

    stats = _get_stats(d)
    assert stats[f"_{candid_hash('total_icvc_burned')}"] == 0
    assert stats[f"_{candid_hash('icvc_pending_burn')}"] == AMOUNT, (
        f"failed burn should leave it pending, got {stats!r}"
    )

    # Heal the ICVC ledger, then an admin sweep flushes the pending burn.
    _set_transfer_fail_mode(d, d.icvc_ledger, 0)
    d.pic.set_sender(DEPLOYER)
    swept = decode(d.pic.update_call(d.redemption, "sweepBurn", encode([])))[0]["value"]
    assert swept.get(f"_{candid_hash('ok')}") == AMOUNT, f"sweepBurn should burn {AMOUNT}, got {swept!r}"

    stats2 = _get_stats(d)
    assert stats2[f"_{candid_hash('icvc_pending_burn')}"] == 0
    assert stats2[f"_{candid_hash('total_icvc_burned')}"] == AMOUNT


def test_force_burn_flushes_pending(pic, redemption_wasm, mock_ledger_wasm):
    # ICP payout succeeds, burn fails -> pendingBurns. forceBurn (admin) clears
    # it with a fresh timestamp; non-admin is refused.
    d = make_mock_deployment(
        pic, redemption_wasm, mock_ledger_wasm,
        icvc_transfer_mode=1, icp_transfer_mode=0,
    )
    d.pic.set_sender(ALICE)
    decode(d.pic.update_call(d.redemption, "redeem", encode(_nat_args(AMOUNT))))
    assert _get_stats(d)[f"_{candid_hash('icvc_pending_burn')}"] == AMOUNT

    d.pic.set_sender(ALICE)
    denied = decode(d.pic.update_call(d.redemption, "forceBurn", encode([])))[0]["value"]
    assert "Not authorized" in denied.get(f"_{candid_hash('err')}", ""), (
        f"non-admin forceBurn should be rejected, got {denied!r}"
    )

    _set_transfer_fail_mode(d, d.icvc_ledger, 0)
    d.pic.set_sender(DEPLOYER)
    burned = decode(d.pic.update_call(d.redemption, "forceBurn", encode([])))[0]["value"]
    assert burned.get(f"_{candid_hash('ok')}") == AMOUNT, f"forceBurn should burn {AMOUNT}, got {burned!r}"
    stats = _get_stats(d)
    assert stats[f"_{candid_hash('icvc_pending_burn')}"] == 0
    assert stats[f"_{candid_hash('total_icvc_burned')}"] == AMOUNT


def test_force_refund_clears_reconciled_icp_send_pending(pic, redemption_wasm, mock_ledger_wasm):
    # ICP payout TRAPS (mode 2) -> entry stuck #IcpSendPending (which retryRefund
    # refuses). ICVC is healthy (mode 0) so the forced refund can go through.
    d = make_mock_deployment(
        pic, redemption_wasm, mock_ledger_wasm,
        icvc_transfer_mode=0, icp_transfer_mode=2,
    )
    d.pic.set_sender(ALICE)
    try:
        d.pic.update_call(d.redemption, "redeem", encode(_nat_args(AMOUNT)))
    except Exception:
        pass  # the trapped payout rejects the redeem call

    entries = _get_inflight(d)
    assert len(entries) == 1
    assert f"_{candid_hash('IcpSendPending')}" in entries[0][f"_{candid_hash('status')}"]
    entry_id = entries[0][f"_{candid_hash('id')}"]

    # retryRefund refuses #IcpSendPending; forceRefund (admin, post-reconciliation)
    # clears it with a fresh created_at_time.
    d.pic.set_sender(ALICE)
    retry = decode(d.pic.update_call(d.redemption, "retryRefund", encode(_nat_args(entry_id))))[0]["value"]
    assert f"_{candid_hash('err')}" in retry, "retryRefund must still refuse #IcpSendPending"

    d.pic.set_sender(DEPLOYER)
    forced = decode(d.pic.update_call(d.redemption, "forceRefund", encode(_nat_args(entry_id))))[0]["value"]
    assert f"_{candid_hash('ok')}" in forced, f"forceRefund should succeed, got {forced!r}"
    assert _get_inflight(d) == [], "entry should be gone after forceRefund"


def test_force_refund_admin_only(pic, redemption_wasm, mock_ledger_wasm):
    d = make_mock_deployment(
        pic, redemption_wasm, mock_ledger_wasm,
        icvc_transfer_mode=0, icp_transfer_mode=0,
    )
    # A non-admin (Alice) must be refused even for an unknown id.
    d.pic.set_sender(ALICE)
    out = decode(d.pic.update_call(d.redemption, "forceRefund", encode(_nat_args(0))))[0]["value"]
    err = out.get(f"_{candid_hash('err')}")
    assert err is not None and "Not authorized" in err, f"non-admin forceRefund should be rejected, got {out!r}"


def test_concurrent_recovery_guard_prevents_double_refund(pic, redemption_wasm, mock_ledger_wasm):
    """Per-id recovery guard: two concurrent forceRefunds on the same
    #RefundPending id must not BOTH settle (that would drain the pool).

    We force the interleave deterministically with a re-entrant mock: armed, the
    ICVC ledger — mid refund-transfer of the OUTER forceRefund (which is parked
    at its transfer await, still holding the per-id guard) — calls BACK into
    forceRefund(id) for the same id. With the guard, that re-entrant call short-
    circuits ("recovery already in progress"), so the ledger sees exactly ONE
    refund transfer. On the pre-guard wasm the re-entrant call runs its own
    transfer -> TWO transfers -> double-refund (this test FAILS there: count==2).

    forceRefund uses a fresh created_at_time, so ledger dedup does NOT save us
    here — the guard is the only thing preventing the double-pay.
    """
    d = make_mock_deployment(
        pic, redemption_wasm, mock_ledger_wasm,
        icvc_transfer_mode=1, icp_transfer_mode=1,
    )
    # Manufacture a stuck #RefundPending (pull ok; ICP send fails; inline refund fails).
    d.pic.set_sender(ALICE)
    decode(d.pic.update_call(d.redemption, "redeem", encode(_nat_args(AMOUNT))))
    entries = _get_inflight(d)
    assert len(entries) == 1
    entry_id = entries[0][f"_{candid_hash('id')}"]
    assert f"_{candid_hash('RefundPending')}" in entries[0][f"_{candid_hash('status')}"]

    # The mock canister re-enters forceRefund as itself, so it must be an admin.
    d.pic.set_sender(DEPLOYER)
    add = decode(d.pic.update_call(
        d.redemption, "addAdmin",
        encode([{"type": Types.Principal, "value": d.icvc_ledger.bytes}]),
    ))[0]["value"]
    assert f"_{candid_hash('ok')}" in add, f"addAdmin(mock) should succeed, got {add!r}"

    # Heal the ICVC ledger, arm the one-shot re-entry, reset the transfer counter.
    _set_transfer_fail_mode(d, d.icvc_ledger, 0)
    d.pic.set_anonymous_sender()
    d.pic.update_call(
        d.icvc_ledger, "setReentrantForceRefund",
        encode([
            {"type": Types.Principal, "value": d.redemption.bytes},
            {"type": Types.Nat, "value": entry_id},
        ]),
    )
    d.pic.update_call(d.icvc_ledger, "resetTransferCount", encode([]))

    # Fire the outer forceRefund; the mock re-enters forceRefund(id) mid-transfer.
    d.pic.set_sender(DEPLOYER)
    forced = decode(d.pic.update_call(d.redemption, "forceRefund", encode(_nat_args(entry_id))))[0]["value"]
    assert f"_{candid_hash('ok')}" in forced, f"outer forceRefund should succeed, got {forced!r}"

    # The decisive assertion: exactly ONE refund transfer hit the ledger.
    d.pic.set_anonymous_sender()
    count = decode(d.pic.query_call(d.icvc_ledger, "getTransferCount", encode([])))[0]["value"]
    assert count == 1, (
        f"recovery guard failed: ledger saw {count} refund transfers for one id "
        f"(expected 1; 2 means a concurrent forceRefund double-paid)"
    )
    assert _get_inflight(d) == [], "entry should be cleared exactly once"


def test_force_close_inflight_real_entry(pic, redemption_wasm, mock_ledger_wasm):
    # Create a real stuck entry (#RefundPending) and clear it with the admin
    # escape hatch.
    d = make_mock_deployment(
        pic, redemption_wasm, mock_ledger_wasm,
        icvc_transfer_mode=1, icp_transfer_mode=1,
    )
    d.pic.set_sender(ALICE)
    decode(d.pic.update_call(d.redemption, "redeem", encode(_nat_args(AMOUNT))))
    entries = _get_inflight(d)
    assert len(entries) == 1
    entry_id = entries[0][f"_{candid_hash('id')}"]

    d.pic.set_sender(DEPLOYER)
    closed = decode(d.pic.update_call(d.redemption, "forceCloseInFlight", encode(_nat_args(entry_id))))[0]["value"]
    assert f"_{candid_hash('ok')}" in closed, f"forceCloseInFlight should succeed, got {closed!r}"
    assert _get_inflight(d) == [], "entry should be gone after forceCloseInFlight"
