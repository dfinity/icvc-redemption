"""Stats math correctness over multiple sequential redeems.

The bash suite verifies one redeem's accounting; here we walk five
sequential redeems and assert every counter increments by exactly the
expected delta. Regression guard for off-by-one drift in the canister's
stats accumulation over many calls. The pool balance is also checked
to drop by exactly `payout + fee` per redeem (the fee is paid by the
canister, not the holder).
"""

from ic.candid import Types, decode, encode
from conftest import ALICE


HASH_OK = 24860
HASH_ERR = 5048165

EXCHANGE_RATE_E8S = 5_753_022  # fair-value derived rate (see #27)
ICP_FEE_E8S = 10_000

# getStats record field hashes (cand_hash of each name)
H_ICP_REMAINING = 2495507349 ^ 0  # placeholder; computed below
# We compute these inline rather than hand-rolling so the test stays
# robust if field names change.


def _cand_hash(s: str) -> int:
    h = 0
    for c in s.encode():
        h = (h * 223 + c) & 0xFFFFFFFF
    return h


H_ICP_REMAINING = _cand_hash("icp_remaining")
H_TOTAL_ICVC_REDEEMED = _cand_hash("total_icvc_redeemed")
H_TOTAL_ICP_DISTRIBUTED = _cand_hash("total_icp_distributed")
H_TOTAL_REDEMPTIONS = _cand_hash("total_redemptions")


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


def _get_stats(deployment) -> dict:
    """Return getStats as a dict keyed by candid field hash."""
    raw = deployment.pic.update_call(deployment.redemption, "getStats", encode([]))
    return decode(raw)[0]["value"]


def test_sequential_redeems_accounting(deployment):
    d = deployment
    redeem_each = 100 * 100_000_000  # 100 ICVC per redeem
    expected_payout = redeem_each * EXCHANGE_RATE_E8S // 100_000_000  # 622_924_400 e8s
    n_redeems = 5

    # Alice faucets ICVC + approves enough for all n redeems.
    d.pic.set_sender(ALICE)
    _ = d.pic.update_call(d.redemption, "faucet", encode([]))
    _ = d.pic.update_call(
        d.icvc_ledger, "icrc2_approve",
        encode(_approve_args(
            spender_owner_bytes=d.redemption.bytes,
            amount=redeem_each * n_redeems + n_redeems * 10_000,  # tiny buffer
        )),
    )

    initial = _get_stats(d)
    initial_icp_remaining = initial[f"_{H_ICP_REMAINING}"]
    initial_total_icvc = initial[f"_{H_TOTAL_ICVC_REDEEMED}"]
    initial_total_icp = initial[f"_{H_TOTAL_ICP_DISTRIBUTED}"]
    initial_count = initial[f"_{H_TOTAL_REDEMPTIONS}"]

    for i in range(1, n_redeems + 1):
        # Advance time between redeems so each gets a unique created_at_time
        # (the canister uses Time.now() for the dedup key on the ICVC pull).
        d.pic.advance_time(2_000_000_000)
        d.pic.tick()

        d.pic.set_sender(ALICE)
        raw = d.pic.update_call(d.redemption, "redeem", encode(_redeem_args(redeem_each)))
        result = decode(raw)[0]["value"]
        assert f"_{HASH_OK}" in result, (
            f"redeem #{i} should succeed, got: {result!r}"
        )

        stats = _get_stats(d)
        # Assertions: each counter must equal initial + (i × per-redeem-delta).
        assert stats[f"_{H_TOTAL_ICVC_REDEEMED}"] == initial_total_icvc + i * redeem_each, (
            f"total_icvc_redeemed wrong after redeem #{i}"
        )
        assert stats[f"_{H_TOTAL_ICP_DISTRIBUTED}"] == initial_total_icp + i * expected_payout, (
            f"total_icp_distributed wrong after redeem #{i}"
        )
        assert stats[f"_{H_TOTAL_REDEMPTIONS}"] == initial_count + i, (
            f"total_redemptions wrong after redeem #{i}"
        )
        # Pool must drop by exactly payout + fee per redeem (fee paid by canister).
        expected_remaining = initial_icp_remaining - i * (expected_payout + ICP_FEE_E8S)
        assert stats[f"_{H_ICP_REMAINING}"] == expected_remaining, (
            f"icp_remaining wrong after redeem #{i}: "
            f"expected {expected_remaining}, got {stats[f'_{H_ICP_REMAINING}']}"
        )
