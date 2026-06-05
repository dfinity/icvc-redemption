"""End-to-end happy-path redeem.

Drives the full swap (faucet → approve → redeem) through PocketIC and
verifies the holder's ICP balance lands at exactly `icvc_amount * rate`.
This isn't closing a documented gap (the bash suite already covers
happy-path redeem), but it's a regression guard for the harness itself:
if the ledger fixtures, init args, or Candid encoding drift, this test
breaks before the deeper tests get a chance to.
"""

from ic.candid import Types, decode, encode
from ic.principal import Principal
from conftest import ALICE


HASH_OK = 24860
HASH_ERR = 5048165
EXCHANGE_RATE_E8S = 5_753_022  # fair-value derived rate (see #27)
ICP_FEE_E8S = 10_000


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


def _balance_of_args(owner: Principal):
    return [{
        "type": _account_type(),
        "value": {"owner": owner.bytes, "subaccount": []},
    }]


def _redeem_args(amount: int):
    return [{"type": Types.Nat, "value": amount}]


def _query_balance(deployment, ledger_principal: Principal, owner: Principal) -> int:
    deployment.pic.set_anonymous_sender()
    raw = deployment.pic.query_call(
        ledger_principal, "icrc1_balance_of", encode(_balance_of_args(owner)),
    )
    decoded = decode(raw)
    return decoded[0]["value"]


def test_redeem_happy_path(deployment):
    d = deployment
    icvc_amount = 100 * 100_000_000  # 100 ICVC in e8s
    expected_icp_payout = icvc_amount * EXCHANGE_RATE_E8S // 100_000_000

    # Step 1: Alice faucets ICVC.
    d.pic.set_sender(ALICE)
    raw_faucet = d.pic.update_call(d.redemption, "faucet", encode([]))
    assert b"cooldown" not in raw_faucet, f"faucet rejected: {raw_faucet!r}"

    # Step 2: Alice approves the redemption canister.
    raw_approve = d.pic.update_call(
        d.icvc_ledger, "icrc2_approve",
        encode(_approve_args(spender_owner_bytes=d.redemption.bytes, amount=icvc_amount + 10_000)),
    )
    decoded_approve = decode(raw_approve)
    assert f"_{HASH_ERR}" not in decoded_approve[0]["value"], (
        f"approve rejected: {decoded_approve!r}"
    )

    # Alice's ICP balance before the redeem (should be 0).
    icp_before = _query_balance(d, d.icp_ledger, ALICE)
    assert icp_before == 0

    # Step 3: redeem.
    d.pic.set_sender(ALICE)
    raw_redeem = d.pic.update_call(d.redemption, "redeem", encode(_redeem_args(icvc_amount)))
    decoded_redeem = decode(raw_redeem)
    result = decoded_redeem[0]["value"]
    assert f"_{HASH_OK}" in result, (
        f"redeem did not return ok: {result!r}"
    )

    # Step 4: Alice should have received exactly the payout amount of ICP
    # (the ledger fee is charged to the sender, i.e. the redemption canister).
    icp_after = _query_balance(d, d.icp_ledger, ALICE)
    assert icp_after == expected_icp_payout, (
        f"expected Alice ICP balance == {expected_icp_payout}, got {icp_after}"
    )

    # Step 5: canister's ICP balance dropped by payout + fee.
    canister_icp = _query_balance(d, d.icp_ledger, d.redemption)
    expected_canister_icp = 100_000_000_000 - expected_icp_payout - ICP_FEE_E8S
    assert canister_icp == expected_canister_icp, (
        f"expected canister ICP balance == {expected_canister_icp}, got {canister_icp}"
    )
