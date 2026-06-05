"""Cooldown boundary precision.

The faucet cooldown is 10 seconds. The canister compares
`elapsed < FAUCET_COOLDOWN_NS` (strictly less), so at `elapsed == cooldown`
the second faucet must succeed (the boundary is inclusive on the high side).
PocketIC also advances time by some non-zero amount during each
`update_call`, so we cannot pin "exactly 1ns under cooldown" precisely;
the meaningful boundary check is "at exactly the cooldown, it releases".
"""

from ic.candid import encode
from conftest import ALICE


FAUCET_COOLDOWN_NS = 10 * 1_000_000_000


def _faucet(deployment, caller):
    deployment.pic.set_sender(caller)
    return deployment.pic.update_call(
        deployment.redemption, "faucet", encode([])
    )


def test_faucet_accepts_at_exact_cooldown(deployment):
    _ = _faucet(deployment, ALICE)
    # Advance by exactly the cooldown. Boundary case: elapsed >= cooldown
    # must NOT reject (the comparison in the canister is `elapsed < cooldown`).
    deployment.pic.advance_time(FAUCET_COOLDOWN_NS)
    deployment.pic.tick()
    raw = _faucet(deployment, ALICE)
    assert b"cooldown" not in raw, (
        f"cooldown should release at the window boundary, got: {raw!r}"
    )
