"""Smoke test for the PocketIC harness.

Confirms the harness can install the redemption canister and that a
public query call returns. Does NOT install the ICVC/ICP ledgers, so
deeper tests (faucet, redeem) need additional fixtures (see README).
"""

from ic.candid import encode, Types
from ic.principal import Principal


# Anonymous principal used as a stand-in for the ledger ids in this smoke test.
ANON = Principal.anonymous()
# Plausible deployer principal (any valid principal will do for the smoke test).
DEPLOYER = Principal.from_str("aaaaa-aa")


def _init_args_list(*, icvc_ledger, icp_ledger, admin) -> list:
    """List-form init args (pocket-ic's install_code encodes internally).
    The exchange rate is derived on-chain, not an init arg (see #27)."""
    return [{
        "type": Types.Record({
            "icvc_ledger_id": Types.Principal,
            "icp_ledger_id": Types.Principal,
            "admin": Types.Principal,
        }),
        "value": {
            "icvc_ledger_id": icvc_ledger.bytes,
            "icp_ledger_id": icp_ledger.bytes,
            "admin": admin.bytes,
        },
    }]


def test_canister_installs_and_returns_admin(pic, redemption_wasm):
    canister_id = pic.create_canister()
    pic.add_cycles(canister_id, 2_000_000_000_000)
    pic.install_code(
        canister_id=canister_id,
        wasm_module=redemption_wasm,
        arg=_init_args_list(
            icvc_ledger=ANON,
            icp_ledger=ANON,
            admin=DEPLOYER,
        ),
    )

    raw = pic.query_call(canister_id, "listAdmins", encode([]))

    # listAdmins returns `vec principal`; on a fresh install it should
    # contain the deployer's principal bytes somewhere in the encoded payload.
    assert DEPLOYER.bytes in raw, "expected the deployer principal in listAdmins output"
