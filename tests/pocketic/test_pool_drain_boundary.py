"""Pool-balance boundary precision.

The canister's pre-flight pool check is:

    if (icp_balance < icp_payout + icp_fee) return #err(#InsufficientIcpPool);

i.e., the boundary `icp_balance == icp_payout + icp_fee` must SUCCEED.
We install with the pool sized to exactly one redeem's cost, do the
redeem (must succeed), then try a second redeem (must reject with
`#InsufficientIcpPool`). This proves the canister cleanly drains to zero
without an off-by-one in the inequality.
"""

from ic.candid import Types, decode, encode
from conftest import ALICE


HASH_OK = 24860
HASH_ERR = 5048165
HASH_INSUFFICIENT_ICP_POOL = 2495455599


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


def _redeem_args(amount: int):
    return [{"type": Types.Nat, "value": amount}]


def test_redeem_drains_pool_to_zero_then_next_rejects(boundary_pool_deployment):
    d = boundary_pool_deployment
    redeem_amount = 100 * 100_000_000  # 100 ICVC matches the fixture's pool size

    # Faucet + approve so Alice has ICVC and the canister has the allowance.
    d.pic.set_sender(ALICE)
    _ = d.pic.update_call(d.redemption, "faucet", encode([]))
    _ = d.pic.update_call(
        d.icvc_ledger, "icrc2_approve",
        encode(_approve_args(spender_owner_bytes=d.redemption.bytes, amount=redeem_amount * 2)),
    )

    # First redeem: pool == cost exactly → boundary check (`<`) must pass.
    raw_first = d.pic.update_call(
        d.redemption, "redeem", encode(_redeem_args(redeem_amount))
    )
    decoded_first = decode(raw_first)[0]["value"]
    assert f"_{HASH_OK}" in decoded_first, (
        f"first redeem (boundary) should succeed, got: {decoded_first!r}"
    )

    # Allow time to drift forward so the second call doesn't dedup against
    # the first (the canister uses Time.now() in its created_at_time field).
    d.pic.advance_time(2_000_000_000)
    d.pic.tick()

    # Second redeem with the pool now at 0: must reject with InsufficientIcpPool.
    raw_second = d.pic.update_call(
        d.redemption, "redeem", encode(_redeem_args(redeem_amount))
    )
    decoded_second = decode(raw_second)[0]["value"]
    err = decoded_second.get(f"_{HASH_ERR}")
    assert err is not None, (
        f"second redeem should be err, got: {decoded_second!r}"
    )
    assert f"_{HASH_INSUFFICIENT_ICP_POOL}" in err, (
        f"expected InsufficientIcpPool after draining, got: {err!r}"
    )
