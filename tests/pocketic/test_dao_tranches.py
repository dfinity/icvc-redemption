"""DAO funding tranches.

Production scenario: the ICVC DAO funds the redemption canister in
tranches via plain `icrc1_transfer` calls from its treasury account.
The canister has no `recordTranche` API (removed in PR #21); the
on-chain truth is whatever the ICP ledger reports as the canister's
balance, and the frontend computes the progress denominator as
`icp_remaining + total_icp_distributed`.

This test simulates the DAO transfer by minting ICP from the ledger's
minting account to the redemption canister, twice, with a holder
redemption in between. It verifies that:

  - `icp_remaining` grows by exactly each tranche amount.
  - A redemption between tranches decreases `icp_remaining` by exactly
    `payout + fee` (the fee is paid by the canister).
  - The progress denominator (`icp_remaining + total_icp_distributed`)
    is monotonically non-decreasing across the whole sequence.
"""

from ic.candid import Types, decode, encode
from conftest import ALICE, DEPLOYER, ICP_MINTING_SUBACCOUNT


HASH_OK = 24860
EXCHANGE_RATE_E8S = 5_758_856  # fair-value derived rate (see #27)
ICP_FEE_E8S = 10_000


def _cand_hash(s: str) -> int:
    h = 0
    for c in s.encode():
        h = (h * 223 + c) & 0xFFFFFFFF
    return h


H_ICP_REMAINING = _cand_hash("icp_remaining")
H_TOTAL_ICP_DISTRIBUTED = _cand_hash("total_icp_distributed")


def _account_type():
    return Types.Record({
        "owner": Types.Principal,
        "subaccount": Types.Opt(Types.Vec(Types.Nat8)),
    })


def _transfer_args(*, from_subaccount: bytes | None, to_owner_bytes: bytes, amount: int):
    """Args for icrc1_transfer. With from_subaccount = ICP_MINTING_SUBACCOUNT
    and sender = DEPLOYER, the ledger treats this as a MINT."""
    return [{
        "type": Types.Record({
            "from_subaccount": Types.Opt(Types.Vec(Types.Nat8)),
            "to": _account_type(),
            "amount": Types.Nat,
            "fee": Types.Opt(Types.Nat),
            "memo": Types.Opt(Types.Vec(Types.Nat8)),
            "created_at_time": Types.Opt(Types.Nat64),
        }),
        "value": {
            "from_subaccount": [from_subaccount] if from_subaccount is not None else [],
            "to": {"owner": to_owner_bytes, "subaccount": []},
            "amount": amount,
            "fee": [],
            "memo": [],
            "created_at_time": [],
        },
    }]


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
    raw = deployment.pic.update_call(deployment.redemption, "getStats", encode([]))
    return decode(raw)[0]["value"]


def _icp_pool_balance(deployment) -> int:
    """Live ICP balance of the redemption canister, read straight from the ICP
    ledger. getStats no longer carries icp_remaining (it's a pure query now)."""
    deployment.pic.set_anonymous_sender()
    arg = encode([{
        "type": _account_type(),
        "value": {"owner": deployment.redemption.bytes, "subaccount": []},
    }])
    return decode(deployment.pic.query_call(deployment.icp_ledger, "icrc1_balance_of", arg))[0]["value"]


def _dao_mint_to_canister(deployment, amount: int) -> None:
    """Simulate the DAO transferring `amount` ICP into the redemption canister.
    Sender is the minting account owner; the from_subaccount is the minting
    subaccount, so the ICP ledger treats this as a mint (no source debit)."""
    deployment.pic.set_sender(DEPLOYER)
    raw = deployment.pic.update_call(
        deployment.icp_ledger,
        "icrc1_transfer",
        encode(_transfer_args(
            from_subaccount=ICP_MINTING_SUBACCOUNT,
            to_owner_bytes=deployment.redemption.bytes,
            amount=amount,
        )),
    )
    # Tag 0 = Ok; the response is `variant { Ok: nat; Err: ... }`.
    # If the mint failed we'd want to see the error.
    decoded = decode(raw)[0]["value"]
    assert "_3456837[78]" not in repr(decoded), f"unexpected mint failure: {decoded!r}"


def test_dao_tranches_grow_pool(deployment):
    d = deployment

    tranche_1 = 10_000 * 100_000_000   # 10,000 ICP e8s
    tranche_2 = 5_000 * 100_000_000    # 5,000 ICP e8s

    initial = _get_stats(d)
    initial_remaining = _icp_pool_balance(d)
    initial_distributed = initial[f"_{H_TOTAL_ICP_DISTRIBUTED}"]
    initial_denominator = initial_remaining + initial_distributed

    # --- Tranche 1: DAO mints 10k ICP into the canister --------------------
    _dao_mint_to_canister(d, tranche_1)
    remaining_after_t1 = _icp_pool_balance(d)
    assert remaining_after_t1 == initial_remaining + tranche_1, (
        f"tranche 1 should grow pool by {tranche_1}, "
        f"saw {remaining_after_t1} (was {initial_remaining})"
    )

    # --- A holder redeems between tranches ----------------------------------
    redeem_amount = 100 * 100_000_000  # 100 ICVC
    expected_payout = redeem_amount * EXCHANGE_RATE_E8S // 100_000_000

    d.pic.set_sender(ALICE)  # Alice is pre-funded with ICVC at genesis
    _ = d.pic.update_call(
        d.icvc_ledger, "icrc2_approve",
        encode(_approve_args(spender_owner_bytes=d.redemption.bytes, amount=redeem_amount + 10_000)),
    )
    raw_redeem = d.pic.update_call(d.redemption, "redeem", encode(_redeem_args(redeem_amount)))
    result = decode(raw_redeem)[0]["value"]
    assert f"_{HASH_OK}" in result, f"redeem failed: {result!r}"

    after_redeem = _get_stats(d)
    remaining_after_redeem = _icp_pool_balance(d)
    expected_after_redeem = initial_remaining + tranche_1 - expected_payout - ICP_FEE_E8S
    assert remaining_after_redeem == expected_after_redeem, (
        f"pool balance wrong after between-tranches redeem"
    )
    assert after_redeem[f"_{H_TOTAL_ICP_DISTRIBUTED}"] == initial_distributed + expected_payout

    # --- Tranche 2: DAO mints another 5k ICP --------------------------------
    _dao_mint_to_canister(d, tranche_2)
    after_t2 = _get_stats(d)
    remaining_after_t2 = _icp_pool_balance(d)
    expected_after_t2 = initial_remaining + tranche_1 + tranche_2 - expected_payout - ICP_FEE_E8S
    assert remaining_after_t2 == expected_after_t2, (
        f"tranche 2 didn't grow pool correctly"
    )

    # --- Monotonicity: the denominator (remaining + distributed) only grows ---
    final_denominator = remaining_after_t2 + after_t2[f"_{H_TOTAL_ICP_DISTRIBUTED}"]
    # After two tranches and one redeem, the denominator grew by exactly
    # (tranche_1 + tranche_2 - fee). The fee is paid by the canister, so it's
    # the only thing that reduces remaining+distributed.
    expected_denominator = initial_denominator + tranche_1 + tranche_2 - ICP_FEE_E8S
    assert final_denominator == expected_denominator, (
        f"denominator (remaining+distributed) wrong: "
        f"initial {initial_denominator}, final {final_denominator}, "
        f"expected {expected_denominator}"
    )
