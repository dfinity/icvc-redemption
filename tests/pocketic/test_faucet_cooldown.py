"""Faucet cooldown: deterministic time advance.

The faucet has a 10-second per-principal cooldown. The bash suite can
verify the cooldown rejects a second immediate call, but cannot
deterministically advance time to verify it re-opens. PocketIC's
advance_time fills that gap.
"""

from ic.candid import encode
from conftest import ALICE


FAUCET_COOLDOWN_NS = 10 * 1_000_000_000


def _faucet(deployment, caller):
    """Issue a faucet update call as `caller`, return raw response bytes."""
    deployment.pic.set_sender(caller)
    return deployment.pic.update_call(
        deployment.redemption, "faucet", encode([])
    )


def test_faucet_cooldown_rejects_within_window(deployment):
    raw_ok = _faucet(deployment, ALICE)
    # First call: should succeed. Easier than parsing the variant — assert
    # the response is not the "cooldown" Text error.
    assert b"cooldown" not in raw_ok, f"first faucet unexpectedly rejected: {raw_ok!r}"

    raw_err = _faucet(deployment, ALICE)
    # Second call within the cooldown window: must come back with a Text
    # error mentioning "cooldown".
    assert b"cooldown" in raw_err, (
        f"second faucet should be rejected with cooldown, got: {raw_err!r}"
    )


def test_faucet_cooldown_clears_after_window(deployment):
    _ = _faucet(deployment, ALICE)
    # Advance just past the cooldown. advance_time takes nanoseconds.
    deployment.pic.advance_time(FAUCET_COOLDOWN_NS + 1_000_000_000)
    deployment.pic.tick()
    raw_ok = _faucet(deployment, ALICE)
    assert b"cooldown" not in raw_ok, (
        f"faucet should succeed after the cooldown window, got: {raw_ok!r}"
    )
