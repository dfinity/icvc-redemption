"""Faucet drains the canister's ICVC supply.

The canister's ICVC supply funds the faucet. Three different callers
each claim 10k ICVC; the canister starts with exactly 3 × (10k ICVC +
ledger fee) so the fourth caller has to hit the ICVC ledger's
InsufficientFunds path. The bash suite doesn't exercise this code path
(it would need either 2k+ faucet calls or a custom-shrunk ledger).
"""

from ic.candid import encode
from conftest import ALICE, BOB, CAROL, DAVE


def _faucet(deployment, caller):
    deployment.pic.set_sender(caller)
    return deployment.pic.update_call(
        deployment.redemption, "faucet", encode([])
    )


def test_faucet_exhausts_supply_then_rejects(tiny_faucet_deployment):
    d = tiny_faucet_deployment

    # Three distinct callers drain the canister's ICVC balance.
    for caller in (ALICE, BOB, CAROL):
        raw = _faucet(d, caller)
        assert b"Transfer failed" not in raw, (
            f"faucet by {caller.to_str()} should succeed (supply not yet exhausted), got: {raw!r}"
        )

    # Fourth caller — supply is now 0; canister can't send the 10k ICVC payout.
    # The ICVC ledger rejects with InsufficientFunds, which the faucet wraps
    # as a Text "Transfer failed: ..." error and restores the previous claim
    # state (so the caller could retry once the canister is refilled).
    raw = _faucet(d, DAVE)
    assert b"Transfer failed" in raw, (
        f"fourth faucet should hit the exhausted-supply path, got: {raw!r}"
    )
    assert b"InsufficientFunds" in raw, (
        f"expected the underlying ICRC-1 InsufficientFunds error inside the "
        f"wrapped text, got: {raw!r}"
    )
