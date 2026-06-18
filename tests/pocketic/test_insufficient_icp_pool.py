"""InsufficientIcpPool: drain the redemption canister and verify the error.

The canister checks `icp_remaining` against the requested payout (plus fee)
before doing any ledger work. If the pool is too small, it should return
`#InsufficientIcpPool` without mutating state. This test installs with a
deliberately tiny ICP pool (0.1 ICP) and tries to redeem 10k ICVC worth
(~623 ICP), which must trip the check.
"""

from ic.candid import Types, decode, encode
from conftest import ALICE


# Candid field hashes (the response carries hashes, not symbol names).
# h(s) = ((((s[0] * 223) + s[1]) * 223 + s[2]) ...) mod 2^32
HASH_ERR = 5048165
HASH_OK = 24860
HASH_INSUFFICIENT_ICP_POOL = 2495455599


# Mirror of Ledger.Account so we can encode icrc2_approve args.
def _account_type():
    return Types.Record({
        "owner": Types.Principal,
        "subaccount": Types.Opt(Types.Vec(Types.Nat8)),
    })


def _approve_args(*, spender_owner_bytes: bytes, amount: int):
    """Build the ICRC-2 approve args. We pull ICVC for the redeem flow."""
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
    """Redemption canister's redeem(amount: nat)."""
    return [{"type": Types.Nat, "value": amount}]


def test_redeem_rejects_when_pool_too_small(small_pool_deployment):
    d = small_pool_deployment

    # Alice is pre-funded with ICVC at genesis. Approve the redemption canister
    # to pull her ICVC — a bit more than we'll redeem to avoid hitting the
    # allowance check first.
    redeem_amount = 10_000 * 100_000_000  # 10k ICVC in e8s ~= 623 ICP needed
    d.pic.set_sender(ALICE)
    d.pic.update_call(
        d.icvc_ledger,
        "icrc2_approve",
        encode(_approve_args(
            spender_owner_bytes=d.redemption.bytes,
            amount=redeem_amount + 10_000,  # tiny buffer over redeem amount
        )),
    )

    # Step 3: Try to redeem. The canister has only 0.1 ICP in its pool but
    # the payout for 10k ICVC at the fixed rate is ~623 ICP, so the pre-flight
    # check must return InsufficientIcpPool.
    raw_redeem = d.pic.update_call(
        d.redemption, "redeem", encode(_redeem_args(redeem_amount)),
    )
    decoded = decode(raw_redeem)
    assert len(decoded) == 1, f"unexpected response shape: {decoded!r}"
    result = decoded[0]["value"]
    err = result.get(f"_{HASH_ERR}")
    assert err is not None, f"expected `err` variant, got: {result!r}"
    assert f"_{HASH_INSUFFICIENT_ICP_POOL}" in err, (
        f"expected InsufficientIcpPool variant, got: {err!r}"
    )
