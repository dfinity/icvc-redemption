"""ICP-send failure paths — the saga recovery the bash suite can't reach.

The bash integration suite runs against healthy ledgers, so it can never make
the ICVC pull succeed and *then* fail the ICP payout — which is the trigger for
the entire refund / journal-recovery machinery. Here we install a real ICVC
ledger plus a fault-injecting mock ICP ledger (see mock_icp_ledger.mo) and
exercise both failure modes:

  * fail_mode=1 (trap): models a lost reply — the payout may have committed, so
    the entry must stay #IcpSendPending and `retryRefund` must REFUSE it (the
    double-spend guard from #48). This is the highest-value gap: the guard
    shipped to mainnet with no test.
  * fail_mode=0 (#Err): a clean ICP failure — the redeem flow does the in-line
    refund, returns #IcpTransferFailed, and clears the saga entry.
"""

from ic.candid import Types, decode, encode
from conftest import ALICE, make_faulty_icp_deployment


def candid_hash(name: str) -> int:
    """ICRC/Candid field-and-variant hash: h = (h*223 + byte) mod 2^32."""
    h = 0
    for b in name.encode():
        h = (h * 223 + b) & 0xFFFFFFFF
    return h


def _account_type():
    return Types.Record({
        "owner": Types.Principal,
        "subaccount": Types.Opt(Types.Vec(Types.Nat8)),
    })


def _approve_args(*, spender_owner_bytes: bytes, amount: int):
    return [{
        "type": Types.Record({
            "from_subaccount": Types.Opt(Types.Vec(Types.Nat8)),
            "spender": _account_type(),
            "amount": Types.Nat,
            "expected_allowance": Types.Opt(Types.Nat),
            "expires_at": Types.Opt(Types.Nat64),
            "fee": Types.Opt(Types.Nat),
            "memo": Types.Opt(Types.Vec(Types.Nat8)),
            "created_at_time": Types.Opt(Types.Nat64),
        }),
        "value": {
            "from_subaccount": [],
            "spender": {"owner": spender_owner_bytes, "subaccount": []},
            "amount": amount,
            "expected_allowance": [],
            "expires_at": [],
            "fee": [],
            "memo": [],
            "created_at_time": [],
        },
    }]


def _nat_args(n: int):
    return [{"type": Types.Nat, "value": n}]


def _approve(d, amount: int):
    # Alice is pre-funded with ICVC at genesis; just approve the canister's pull.
    d.pic.set_sender(ALICE)
    d.pic.update_call(
        d.icvc_ledger, "icrc2_approve",
        encode(_approve_args(spender_owner_bytes=d.redemption.bytes, amount=amount + 10_000)),
    )


def _get_inflight(d):
    d.pic.set_anonymous_sender()
    return decode(d.pic.query_call(d.redemption, "getInFlight", encode([])))[0]["value"]


def test_icp_send_trap_leaves_pending_and_retry_refused(
    pic, redemption_wasm, icrc1_wasm, mock_icp_wasm
):
    d = make_faulty_icp_deployment(
        pic, redemption_wasm, icrc1_wasm, mock_icp_wasm, fail_mode=1,
    )
    amount = 100 * 100_000_000  # 100 ICVC
    _approve(d, amount)

    # The mock ICP ledger traps on the payout AFTER the ICVC pull committed, so
    # the redeem call rejects and the saga entry is left in #IcpSendPending.
    d.pic.set_sender(ALICE)
    try:
        d.pic.update_call(d.redemption, "redeem", encode(_nat_args(amount)))
    except Exception:
        pass  # the trapped payout rejects the redeem call — expected

    entries = _get_inflight(d)
    assert len(entries) == 1, f"expected exactly one in-flight entry, got {entries!r}"
    status = entries[0][f"_{candid_hash('status')}"]
    assert f"_{candid_hash('IcpSendPending')}" in status, (
        f"entry should be #IcpSendPending (ICP outcome unknown), got {status!r}"
    )
    entry_id = entries[0][f"_{candid_hash('id')}"]

    # The double-spend guard: retryRefund must REFUSE this entry, because the
    # ICP payout may have settled. It returns #err with a reconcile message.
    d.pic.set_sender(ALICE)
    raw_retry = d.pic.update_call(d.redemption, "retryRefund", encode(_nat_args(entry_id)))
    result = decode(raw_retry)[0]["value"]
    assert f"_{candid_hash('err')}" in result, (
        f"retryRefund must refuse #IcpSendPending with #err, got {result!r}"
    )
    msg = result[f"_{candid_hash('err')}"]
    assert ("IcpSendPending" in msg) or ("reconcile" in msg) or ("double-pay" in msg), (
        f"refusal should explain reconciliation, got: {msg!r}"
    )

    # And it must NOT have refunded: still exactly one #IcpSendPending entry.
    entries_after = _get_inflight(d)
    assert len(entries_after) == 1, (
        f"retryRefund must not remove/refund a #IcpSendPending entry, got {entries_after!r}"
    )


def test_icp_send_err_triggers_inline_refund(
    pic, redemption_wasm, icrc1_wasm, mock_icp_wasm
):
    d = make_faulty_icp_deployment(
        pic, redemption_wasm, icrc1_wasm, mock_icp_wasm, fail_mode=0,
    )
    amount = 100 * 100_000_000  # 100 ICVC
    _approve(d, amount)

    # Clean ICP failure (#Err): redeem does the in-line refund via the real ICVC
    # ledger, returns #IcpTransferFailed, and clears the saga entry.
    d.pic.set_sender(ALICE)
    raw = d.pic.update_call(d.redemption, "redeem", encode(_nat_args(amount)))
    result = decode(raw)[0]["value"]
    assert f"_{candid_hash('err')}" in result, f"expected #err, got {result!r}"
    err = result[f"_{candid_hash('err')}"]
    assert f"_{candid_hash('IcpTransferFailed')}" in err, (
        f"expected #IcpTransferFailed after in-line refund, got {err!r}"
    )

    # The in-line refund succeeded, so the saga journal is empty again.
    assert _get_inflight(d) == [], "in-line refund should have cleared the entry"
